# Why one key's events step one at a time

A parcel's scans arrive from the depot, the carrier and the van, and they all
address one execution. The router steps that execution with one event at a
time. This page is about why it is built that way, what the Broadway
partitioner adds on top, and what that costs a key that is very busy.

## The lock is the guarantee, the partitioner is an optimisation

`StatifierRouter.Broadway` partitions by key, so every message for one key
reaches the router on one processor, one after another, instead of queueing
on a lock. The partitioner is not what keeps the order safe. Each delivery
steps its execution under statifier_persistence's per-execution lock and holds
that lock until its transaction commits, so two events for one execution are
stepped one at a time, in the order the lock grants them, whether or not they
came through the front: a webhook, a form post and a pipeline message for the
same parcel serialize the same way.

The two together keep a processor from waiting on a lock it was always going
to wait on. A binding whose `order` is `:none` gives up the partitioning, and
its events still step one at a time under the lock, with processors waiting
on it.

## What one delivery costs

Partitioning spreads keys across processors; it never spreads one key. Every
event for one address runs in order on one processor and steps its execution
under that execution's lock, and each delivery that steps it is one
transaction of several row writes: the dedupe claim, the execution's step (its
stored position and the event appended to its input log), the routing ledger
row, and on a key's first event the address row and the new execution. So the
rate for one key is one delivery transaction after another, whatever the
processor count: more processors raise the rate across keys, never the rate
for one key.

That ceiling is a property of the design, not a figure this package promises;
where it falls depends on the host's database and charts. The alternative, two
events of one execution stepped at once, would leave two positions of one
chart to reconcile, and the input log would no longer say which event came
first; one transaction per event is what keeps that record exact.

## When one key is too busy

A key hot enough to meet the ceiling has three pressure valves, in this order:

- **Fold its events into one.** The host combines a burst of one key's events
  into one chart event that carries them together, before they are routed. The
  pipeline has no batchers, so the folding is the host's, in its producer or
  ahead of it.
- **A live session for the hot key.** The host runs that key's chart in a
  `Statifier.Session`, stepped in memory rather than by one durable delivery
  per event; what it gives up is the per-event durable record a delivery
  writes.
- **Join upstream.** For a true firehose, the high-volume join runs in the
  source layer or a dedicated stream processor, and its outcomes, not its raw
  events, are routed into charts.

The order matters: folding keeps every guarantee and only changes the event's
shape; a live session keeps the chart and gives up durability per event;
joining upstream takes the work out of charts altogether.
