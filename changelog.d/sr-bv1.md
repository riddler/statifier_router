### Changed

- `StatifierRouter.Broadway.start_link/1` raises `ArgumentError` when `:name`
  is missing or is not an atom, as its options table has always said it would;
  it previously started an unnamed pipeline instead.
- The Broadway front's documentation and the README no longer say a failed
  message is handed over again by the source: Broadway retries nothing, so
  redelivery is the producer's contract, and `BroadwayKafka.Producer`
  acknowledges failed messages and advances past them.
