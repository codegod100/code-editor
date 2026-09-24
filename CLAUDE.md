# Modal log context

When the user pastes a Modal app or deployment URL, query the linked app's logs directly through the Modal API or CLI before responding. Do not use browser automation for log retrieval. Use the URL's time range when present, and surface relevant log context in the response.

# Scope of user requests

Unless the user explicitly says otherwise, interpret requests to change settings, applications, terminals, or other local tooling as requests about this shared app/workspace—not the user's personal computer or account-level configuration. Do not make personal-device or account-wide changes without explicit authorization.
