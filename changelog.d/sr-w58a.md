### Added

- `StatifierRouter.Migrations.up/1` takes a `:primary_key` option, `[type: ..., default: ...]`, that builds the `id` of every table a version creates with the host's own key type and database default, a text id for instance; the schemas read the id back as an integer or a string through the new `StatifierRouter.Schema.Id`, and `StatifierRouter.Addresses.reap/2` sweeps a text-keyed table, answering a string `next` cursor it takes back as `after:`. Left out, every version builds exactly the tables it built before.
