# How to route a producer's messages through the Broadway pipeline

This guide puts a message queue the host already operates in front of the
router, so every scan a producer hands over is matched against the bindings,
addressed, and delivered to its parcel's durable execution. It starts from a
working `%StatifierRouter.Config{}` (the README's Basic usage builds one) and a
[Broadway](https://hexdocs.pm/broadway) producer for the queue.

The front of this package is Broadway. `StatifierRouter.Broadway` is the
pipeline; the host starts it in its own supervision tree, and `partition_by`
keeps every message for one key on one processor. Why that matters, and what
it does not promise, is in
[Why one key's events step one at a time](../explanation/one-key-at-a-time.md).

## Step 1. Add the pipeline to the host's supervision tree

`StatifierRouter.Broadway` goes in the host's own supervision tree, after the
repo, with the producer it already operates and the router's configuration:

```elixir
children = [
  MyApp.Repo,
  {StatifierRouter.Broadway,
   name: MyApp.ParcelScansRouter,
   producer: {BroadwayKafka.Producer, kafka_opts},
   router: router_config,
   processors: [default: [concurrency: 8]]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

`router_config` is a `%StatifierRouter.Config{}`. `Supervisor.start_link/2`
answers `{:ok, pid}` once the pipeline and its producer have started; an
error there names the child that did not.

## Step 2. Say where each message's scope, id and source are

By default each message's `scope`, `message_id` and `source` are read from its
metadata and its data is the normalized event. A producer that carries them
elsewhere is paired with a `:normalize` function of the host's own. A message
whose routing returns an error, or raises, is failed rather than passed on as
a success, so a message missing its `message_id` shows up as a failed message,
not a silent one.

## Step 3. Decide what happens to a failed message

Whether a failed message is handed over again is the **producer's** contract,
not Broadway's: Broadway provides no retries of its own and acknowledges a
failed message as failed immediately. A queue-style producer that leaves an
unacknowledged message invisible for a timeout, Amazon SQS the example
Broadway itself names, gives the event back; `BroadwayKafka.Producer`, the
producer in the snippet above, acknowledges failed messages too and advances
the group's offset past them, so reprocessing is a strategy the host rolls. A
host that needs a failed delivery retried picks a producer that gives it back,
or arranges the replay itself.

Check it by failing one delivery on purpose (a resolver that answers
`{:error, reason}`, say) and watching whether the producer offers the message
again.

## Step 4. Choose each binding's order

A binding whose `order` is `:none` is not partitioned by its key: its events
spread across processors and still step one at a time under the execution's
lock. Every other binding keeps one key on one processor. The default is
`:by_key`; leave it unless one key's events are slowed by queueing on the
lock; the explanation page above says when that happens and what to do
instead.
