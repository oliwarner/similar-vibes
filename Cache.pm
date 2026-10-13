package Plugins::SimilarVibes::Cache;

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Prefs;

my $cache = Slim::Utils::Cache->new('similarvibes', 1);
my $prefs = preferences('plugin.similarvibes');

sub get_data {
	my ($class, $key) = @_;
	my $entry = $cache->get($key) or return;
	my $ttl = ($prefs->get('cache_expiry_days') || 30) * 86400;
	if (!$entry->{cached_at} || time - $entry->{cached_at} >= $ttl) {
		$cache->remove($key);
		return;
	}
	return $entry->{data};
}

sub set_data {
	my ($class, $key, $data) = @_;
	my $ttl = ($prefs->get('cache_expiry_days') || 30) * 86400;
	$cache->set($key, { cached_at => time, data => $data }, $ttl . ' seconds');
}

sub mark_played {
	my ($class, $track_id) = @_;
	my $hours = $prefs->get('recently_played_hours') || 0;
	return unless $track_id && $hours;
	$cache->set("played:$track_id", time, ($hours * 3600) . ' seconds');
}

sub was_played_recently {
	my ($class, $track_id) = @_;
	my $hours = $prefs->get('recently_played_hours') || 0;
	return 0 unless $track_id && $hours;
	return $cache->get("played:$track_id") ? 1 : 0;
}

1;