### Added

- `StatifierRouter.Webhook.handle/3` routes one verified webhook request,
  taking the message id from the provider's event id or, absent one, the
  lowercase hex SHA-256 of the raw body.
- `StatifierRouter.Webhook.status/1` answers the HTTP status a provider
  should see for one `handle/3` answer: `200` for a recorded outcome, `500`
  for an error.
