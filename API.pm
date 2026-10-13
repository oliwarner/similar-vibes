package Plugins::SimilarVibes::API;

use strict;

use JSON::XS qw(decode_json);
use Slim::Networking::SimpleAsyncHTTP;
use Plugins::SimilarVibes::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes ();
use URI::Escape qw(uri_escape_utf8);

my $prefs = preferences('plugin.similarvibes');
my @listenbrainz_queue;
my $listenbrainz_active = 0;
my $listenbrainz_timer_pending = 0;
my $last_listenbrainz_request = 0;

sub get_similar_artists {
	my ($class, $name, $mbid, $callback) = @_;
	my $provider = $prefs->get('api_provider') || 'lastfm';
	my $key = _identity($name, $mbid);
	if (my $cached = Plugins::SimilarVibes::Cache->get_data("similar:$provider:$key")) {
		return $callback->($cached);
	}
	if ($provider ne 'lastfm' || !$prefs->get('lastfm_api_key')) {
		return $callback->([]);
	}
	my $url = 'https://ws.audioscrobbler.com/2.0/?method=artist.getsimilar&artist='
		. uri_escape_utf8($name) . '&api_key=' . uri_escape_utf8($prefs->get('lastfm_api_key'))
		. '&format=json&limit=50';
	return _request_json($url, sub {
		my ($data) = @_;
		my $artists = ref $data->{similarartists}->{artist} eq 'ARRAY'
			? $data->{similarartists}->{artist}
			: $data->{similarartists}->{artist} ? [$data->{similarartists}->{artist}] : [];
		my @result = map { +{ name => $_->{name}, mbid => $_->{mbid} || undef } }
			grep { ref $_ eq 'HASH' && $_->{name} } @$artists;
		Plugins::SimilarVibes::Cache->set_data("similar:$provider:$key", \@result);
		$callback->(\@result);
	});
}

sub get_top_tracks {
	my ($class, $name, $mbid, $callback) = @_;
	my $provider = $prefs->get('api_provider') || 'lastfm';
	my $key = _identity($name, $mbid);
	if (my $cached = Plugins::SimilarVibes::Cache->get_data("top:$provider:$key")) {
		return $callback->($cached);
	}
	if ($provider eq 'lastfm') {
		return $callback->([]) unless $prefs->get('lastfm_api_key');
		my $url = 'https://ws.audioscrobbler.com/2.0/?method=artist.gettoptracks&artist='
			. uri_escape_utf8($name) . '&api_key=' . uri_escape_utf8($prefs->get('lastfm_api_key'))
			. '&format=json&limit=10';
		return _request_json($url, sub {
			my ($data) = @_;
			my $tracks = ref $data->{toptracks}->{track} eq 'ARRAY'
				? $data->{toptracks}->{track}
				: $data->{toptracks}->{track} ? [$data->{toptracks}->{track}] : [];
			my @result = map { +{ name => $_->{name} } } grep { ref $_ eq 'HASH' && $_->{name} } @$tracks;
			Plugins::SimilarVibes::Cache->set_data("top:$provider:$key", \@result);
			$callback->(\@result);
		});
	}

	return $callback->([]) unless $mbid;
	my $url = 'https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/' . uri_escape_utf8($mbid);
	my %headers = ('User-Agent' => 'SimilarVibes/1.0 (Lyrion Music Server plugin)');
	$headers{Authorization} = 'Token ' . $prefs->get('listenbrainz_token') if $prefs->get('listenbrainz_token');
	return _request_json($url, sub {
		my ($data) = @_;
		my @result = map { +{ name => $_->{recording_name}, mbid => $_->{recording_mbid} } }
			grep { ref $_ eq 'HASH' && $_->{recording_name} } ref $data eq 'ARRAY' ? @$data : ();
		@result = @result[0 .. 9] if @result > 10;
		Plugins::SimilarVibes::Cache->set_data("top:$provider:$key", \@result);
		$callback->(\@result);
	}, \%headers, 1);
}

sub _request_json {
	my ($url, $callback, $headers, $throttle) = @_;
	if ($throttle) {
		push @listenbrainz_queue, [$url, $callback, $headers];
		_dispatch_listenbrainz();
		return;
	}
	_send_json_request($url, $callback, $headers);
}

sub _dispatch_listenbrainz {
	return if $listenbrainz_active || !@listenbrainz_queue;
	my $wait = 1 - (Time::HiRes::time() - $last_listenbrainz_request);
	if ($wait > 0) {
		return if $listenbrainz_timer_pending;
		$listenbrainz_timer_pending = 1;
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $wait, sub {
			$listenbrainz_timer_pending = 0;
			_dispatch_listenbrainz();
		});
		return;
	}

	my ($url, $callback, $headers) = @{shift @listenbrainz_queue};
	$listenbrainz_active = 1;
	$last_listenbrainz_request = Time::HiRes::time();
	_send_json_request($url, $callback, $headers, sub {
		$listenbrainz_active = 0;
		_dispatch_listenbrainz();
	});
}

sub _send_json_request {
	my ($url, $callback, $headers, $on_done) = @_;
	my $finish = sub {
		$on_done->() if $on_done;
	};
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $data = eval { decode_json($response->content || '') };
			$callback->(ref $data eq 'HASH' || ref $data eq 'ARRAY' ? $data : {});
			$finish->();
		},
		sub {
			$callback->({});
			$finish->();
		},
		{ timeout => 15 },
	);
	$http->get($url, %{$headers || {}});
	return;
}

sub _identity {
	my ($name, $mbid) = @_;
	return lc($mbid || $name || '');
}

1;