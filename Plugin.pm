package Plugins::SimilarVibes::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.similarvibes');

sub initPlugin {
	my $class = shift;

	$prefs->init({
		api_provider            => 'lastfm',
		lastfm_api_key          => '',
		listenbrainz_token      => '',
		cache_expiry_days       => 30,
		max_similar_artists     => 5,
		recently_played_hours   => 24,
	});
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 365 }, 'cache_expiry_days');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 20 }, 'max_similar_artists');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 720 }, 'recently_played_hours');

	$class->SUPER::initPlugin(@_);
	require Plugins::SimilarVibes::Provider;
	require Plugins::SimilarVibes::Cache;

	if (main::WEBUI) {
		require Plugins::SimilarVibes::Settings;
		Plugins::SimilarVibes::Settings->new;
	}

	return 1;
}

sub postinitPlugin {
	return unless Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin');

	require Slim::Plugin::DontStopTheMusic::Plugin;
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
		'SimilarVibes',
		\&Plugins::SimilarVibes::Provider::get_tracks
	);
	Slim::Control::Request::subscribe(\&_track_started, [['playlist'], ['newsong']]);
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_track_started);
	if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('SimilarVibes');
	}
	return shift->SUPER::shutdownPlugin(@_);
}

sub _track_started {
	my $request = shift;
	my $client = $request->client || return;
	$client = $client->master;
	my $index = Slim::Player::Source::streamingSongIndex($client);
	my $playlist = Slim::Player::Playlist::playList($client) || [];
	my $track = $playlist->[$index] or return;
	$track = Slim::Schema->objectForUrl($track) unless ref $track;
	return unless $track && $track->can('id');

	Plugins::SimilarVibes::Cache->mark_played($track->id);
	Plugins::SimilarVibes::Provider::precache_track($client, $track);
}

1;

package Plugins::SimilarVibes::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.similarvibes');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('SimilarVibes');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/DStM-SimilarVibes/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(api_provider lastfm_api_key listenbrainz_token cache_expiry_days max_similar_artists recently_played_hours));
}

1;