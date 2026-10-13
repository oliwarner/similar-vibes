package Plugins::SimilarVibes::Provider;

use strict;

use Plugins::SimilarVibes::API;
use Plugins::SimilarVibes::Cache;
use Slim::Control::Request;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Schema;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.similarvibes');

sub get_tracks {
	my ($client, $callback) = @_;
	return $callback->($client, []) unless $client && $callback;
	$client = $client->master;

	my $seed = _current_track($client);
	return $callback->($client, []) unless $seed;
	my $artist = _artist_for_track($seed);
	return $callback->($client, []) unless $artist;

	my $seed_name = $artist->name;
	my $seed_mbid = $artist->musicbrainz_id;
	Plugins::SimilarVibes::API->get_similar_artists($seed_name, $seed_mbid, sub {
		my ($similar) = @_;
		my @artists = _local_artists($similar, $seed_name);
		if (!@artists) {
			@artists = _genre_artists($seed, $seed_name);
		}
		my $artist_limit = $prefs->get('max_similar_artists') || 5;
		@artists = @artists[0 .. $artist_limit - 1] if @artists > $artist_limit;
		return _get_artist_pools($client, \@artists, [], sub {
			my ($pools) = @_;
			$callback->($client, _select_tracks($client, $pools));
		});
	});
}

sub precache_track {
	my ($client, $track) = @_;
	my $artist = _artist_for_track($track) or return;
	Plugins::SimilarVibes::API->get_similar_artists(
		$artist->name,
		$artist->musicbrainz_id,
		sub { return }
	);
}

sub _current_track {
	my $client = shift;
	my $index = Slim::Player::Source::streamingSongIndex($client);
	my $playlist = Slim::Player::Playlist::playList($client) || [];
	my $track = $playlist->[$index] or return;
	$track = Slim::Schema->objectForUrl($track) unless ref $track;
	return $track if $track && $track->can('id');
	return;
}

sub _artist_for_track {
	my $track = shift;
	my $artist = eval { $track->artist };
	return $artist if $artist && $artist->name;
	my $name = eval { $track->artistName } || eval { $track->artist };
	return unless $name;
	my @matches = Slim::Schema->rs('Contributor')->search({ name => $name })->all;
	return $matches[0];
}

sub _local_artists {
	my ($similar, $seed_name) = @_;
	my @local;
	my %seen;
	for my $entry (@{$similar || []}) {
		my $name = ref $entry eq 'HASH' ? $entry->{name} : $entry;
		my $mbid = ref $entry eq 'HASH' ? $entry->{mbid} : undef;
		next unless $name && lc($name) ne lc($seed_name || '');
		my @matches = $mbid
			? Slim::Schema->rs('Contributor')->search({ musicbrainz_id => $mbid })->all
			: Slim::Schema->rs('Contributor')->search({ name => $name })->all;
		for my $artist (@matches) {
			next unless $artist && $artist->id && _is_artist($artist) && !$seen{$artist->id}++;
			push @local, $artist;
			last;
		}
	}
	return @local;
}

sub _is_artist {
	my $artist = shift;
	return $artist->contributorTracks->search({ role => { in => [1, 6] } })->count ? 1 : 0;
}

sub _genre_artists {
	my ($seed, $seed_name) = @_;
	my @genres = eval { $seed->genres->all };
	my %artists;
	for my $genre (@genres) {
		next unless $genre && $genre->id;
		my $request = Slim::Control::Request::executeRequest(undef, ['artists', 0, 999999, 'genre_id:' . $genre->id]);
		for my $row (@{$request->getResult('artists_loop') || []}) {
			my $artist = Slim::Schema->rs('Contributor')->find($row->{id});
			$artists{$artist->id} = $artist if $artist && $artist->id && lc($artist->name || '') ne lc($seed_name || '');
		}
	}
	my @artists = values %artists;
	Slim::Player::Playlist::fischer_yates_shuffle(\@artists) if @artists > 1;
	return @artists;
}

sub _get_artist_pools {
	my ($client, $artists, $pools, $done) = @_;
	return $done->($pools) unless @$artists;
	my $artist = shift @$artists;
	Plugins::SimilarVibes::API->get_top_tracks($artist->name, $artist->musicbrainz_id, sub {
		my ($top_tracks) = @_;
		my $pool = _local_tracks_for_artist($artist, $top_tracks);
		push @$pools, $pool if @$pool;
		_get_artist_pools($client, $artists, $pools, $done);
	});
}

sub _local_tracks_for_artist {
	my ($artist, $top_tracks) = @_;
	my @tracks = eval { $artist->contributorTracks->search({ role => { in => [1, 6] } })->search_related('track')->distinct->all };
	my %by_title;
	for my $track (@tracks) {
		my $title = eval { $track->title } || '';
		$by_title{lc $title} ||= $track if length $title;
	}
	my @pool;
	my %seen;
	for my $entry (@{$top_tracks || []}) {
		my $title = ref $entry eq 'HASH' ? ($entry->{name} || $entry->{title}) : $entry;
		my $mbid = ref $entry eq 'HASH' ? $entry->{mbid} : undef;
		my $track;
		if ($mbid) {
			($track) = grep { (eval { $_->musicbrainz_id } || '') eq $mbid } @tracks;
		}
		$track ||= $by_title{lc $title} if defined $title;
		push @pool, $track if $track && !$seen{$track->id}++;
		last if @pool >= 10;
	}
	my @fill = grep { $_ && !$seen{$_->id}++ } @tracks;
	Slim::Player::Playlist::fischer_yates_shuffle(\@fill) if @fill > 1;
	push @pool, splice(@fill, 0, 10 - @pool) if @pool < 10;
	return \@pool;
}

sub _select_tracks {
	my ($client, $pools) = @_;
	my %queued;
	for my $item (@{Slim::Player::Playlist::playList($client) || []}) {
		my $track = ref $item ? $item : Slim::Schema->objectForUrl($item);
		$queued{$track->id} = 1 if $track && $track->can('id');
	}
	my @available;
	for my $pool (@$pools) {
		my @eligible = grep {
			$_ && !$queued{$_->id} && !Plugins::SimilarVibes::Cache->was_played_recently($_->id)
		} @$pool;
		Slim::Player::Playlist::fischer_yates_shuffle(\@eligible) if @eligible > 1;
		push @available, \@eligible if @eligible;
	}
	my @selected;
	my $target = $prefs->get('max_similar_artists') || 5;
	while (@selected < $target) {
		my $added = 0;
		for my $pool (@available) {
			while (@$pool) {
				my $track = shift @$pool;
				next if $queued{$track->id}++;
				push @selected, $track;
				$added = 1;
				last;
			}
			last if @selected >= $target;
		}
		last unless $added;
	}
	return \@selected;
}

1;