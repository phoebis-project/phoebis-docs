# Phoebis

Phoebis is a router for Claude Code with two programs that attach to it. This site documents each of the three in a
part of its own.

- [Phoebis Router](router/index.md) relays Claude Code's requests to Anthropic under the credentials of an account it
  holds and picks that account from a pool. Its part is for the operator who installs and runs the router, and for
  the user who points a client at it.
- [Phoebis Companion](companion/index.md) is a Claude Code plugin that reports session liveness and agent state to the
  router and gives the model one tool, which reads what the key's pool has left. Its part is for the operator who
  installs and configures the mod on a client machine.
- [Phoebis Proxy](proxy/index.md) is a tunnel proxy that ends the tunnels of two claude.ai features, Artifacts and
  the connectors, at the router. Its part is for the operator who wants those two features behind the router.
