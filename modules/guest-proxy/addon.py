"""Entry point mitmproxy loads (`-s`): builds the guard from the environment. An error here stops
mitmproxy at startup, so the proxy never runs without its policy."""

import guard

guard.setup_logging()
addons = [guard.from_environment()]
