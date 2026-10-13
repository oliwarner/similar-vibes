# SimilarVibes

SimilarVibes is a Lyrion Music Server (LMS) **Don't Stop The Music (DStM)** provider. When DStM asks it for more music, it uses the artist of the current local track as a seed, finds related artists that are in the local library, and returns local tracks for DStM to append. External requests use LMS's asynchronous HTTP client, so they do not wait synchronously on the server's event loop.

## Package contents

The package is a flat LMS plugin directory. Install the files so `install.xml` and `Plugin.pm` are at the plugin root, preserving the `HTML` directory:

```text
SimilarVibes/
|-- install.xml
|-- Plugin.pm
|-- Provider.pm
|-- API.pm
|-- Cache.pm
`-- HTML/
    `-- EN/plugins/DStM-SimilarVibes/settings/basic.html
```

The manifest loads `Plugins::SimilarVibes::Plugin` and advertises the settings URL. LMS loads the other modules from the same plugin package. The plugin requires DStM to be installed and enabled; it registers its handler during LMS's plugin post-initialization phase, after DStM has loaded.

## Setup

1. Install the directory in an LMS plugin location and restart LMS so it reads the manifest and loads the plugin.
2. Open the SimilarVibes settings page from LMS settings.
3. Choose a data source and enter the applicable credential.
4. In DStM settings, select **SimilarVibes** as the provider for the player.

The settings include:

| Setting | Default | Behavior |
| --- | ---: | --- |
| Music data source | Last.fm | Selects Last.fm or ListenBrainz for top-track data. |
| Last.fm API key | Empty | Required for Last.fm similarity and top-track requests. |
| ListenBrainz user token | Empty | Sent as an authorization token when supplied; the public top-recordings endpoint can also be queried without one. |
| Cache expiry | 30 days | Expiry for cached similarity and top-track responses; accepted range is 1-365 days. |
| Maximum similar artists | 5 | Caps the number of local artists considered and sets the number of tracks requested from the selection loop; accepted range is 1-20. |
| Exclude tracks played within | 24 hours | Duration for excluding track IDs observed playing since the plugin started; `0` disables this filter. Accepted range is 0-720 hours. |

## What happens when a track starts

The plugin subscribes to LMS playlist `newsong` notifications. On each notification it:

1. Resolves the player's current playlist item to an LMS track object. If it is a local database track, it records that track ID in the recent-play cache for the configured number of hours.
2. Gets the track's primary artist and asks the API module for similar artists. With a valid Last.fm API key, this request runs in the background. If the response is already cached, the callback is immediate.
3. Stores successful similar-artist results in the LMS persistent cache. This is background pre-caching; it does not add tracks to the queue by itself.

The cache is LMS's `Slim::Utils::Cache` with a separate `similarvibes` namespace. It is backed by LMS's cache database, not a plugin-managed JSON file. Cache entries also contain their creation time and are checked against the current configured TTL when read.

## DStM selection flow

When DStM invokes the SimilarVibes provider, the provider:

1. Uses the artist of the player's current playlist track as the seed. If there is no current local track or no resolvable artist, it returns an empty list.
2. Gets similar artists from the selected data source. For Last.fm, SimilarVibes calls `artist.getSimilar`. API errors, missing credentials, or an empty result produce no similar-artist list.
3. Resolves those names against LMS contributors. If a similar artist has a MusicBrainz ID, that ID is matched first; otherwise the artist name is matched. Only contributors with tracks credited in the ARTIST or TRACKARTIST roles are retained. The seed itself and duplicate local artist IDs are omitted.
4. If **no** similar artists match the local library, it finds artists from the seed track's local genres and shuffles that artist list. This is a local fallback; it does not make a second external similarity request for the fallback artist.
5. For each retained artist, in sequence, it fetches top tracks from the selected source. It resolves API track IDs when available, otherwise compares track titles case-insensitively against that artist's local tracks. A pool is filled to at most 10 tracks with other local tracks by that artist, shuffled randomly.
6. It removes tracks already present anywhere in the player's playlist and tracks in the recent-play cache. It shuffles each remaining pool, then takes one track from each artist pool per round until it reaches the configured maximum or exhausts the pools. If fewer artist pools are available than the target, later rounds can take additional tracks from an available pool.
7. Returns local LMS track objects to DStM through DStM's callback. DStM handles appending and its own playlist de-duplication.

If no candidate tracks remain, SimilarVibes returns an empty list. The plugin does not directly invoke DStM's built-in fallback provider.

## Data sources

### Last.fm

Last.fm is the default and only source that supplies both steps of the remote pipeline:

- Similar artists: `artist.getSimilar`, queried by artist name.
- Popular tracks: `artist.getTopTracks`, queried by artist name with a limit of 10.

Both requests require a Last.fm API key. Returned top-track names are matched to the local artist's track titles; Last.fm track results are not resolved by recording ID in this implementation.

### ListenBrainz

ListenBrainz is used for top recordings through `/1/popularity/top-recordings-for-artist/{artist_mbid}`. A local artist MusicBrainz ID is required to make that request; without one, no remote top tracks are returned and the local randomized fill is used.

ListenBrainz does not provide a documented seed-based similar-artist endpoint used by this plugin. When ListenBrainz is selected, the similarity stage therefore yields no remote artists and the provider uses the seed's local genres to find candidate artists. The top-recordings response is matched using recording MusicBrainz IDs where possible, then by title. ListenBrainz requests are queued and dispatched no more than once per second. A user token is sent if configured, and requests include a User-Agent header.

## Failure behavior and current scope

- HTTP errors and invalid JSON become empty API results. The provider then uses the genre fallback if it has not already found local similar artists.
- If genre lookup returns no usable artists, or their pools contain no eligible tracks, the callback receives an empty list.
- A pool is filled with shuffled local tracks, not playcount-ranked tracks. No playcount correlation is implemented.
- Recent-play filtering is based on `newsong` events seen since SimilarVibes was running. It does not query LMS statistics for historical `lastplayed` values.
- The genre fallback uses the seed track's local genres and does not retry similarity lookup using a random fallback artist.
- The configured maximum is both the artist-list cap and the requested selection count. It is not derived from DStM's current queue deficit.
- The API layer does not retry failed requests or cache failed responses. Last.fm throttling/errors simply result in the local fallback path.

## Development checks

The modules depend on LMS classes and cannot be loaded as a standalone Perl application. In a development environment without LMS, basic syntax can be checked with Perl stubs for LMS modules. Validate `install.xml` as XML and verify the settings form's `pref_` names against the preference names returned by `Plugins::SimilarVibes::Settings::prefs`.