# Replay Collector
This apps discovers Wiis on the network, connects to them
and records incoming Slippi Replays.

## TODO
- [ ] Implement Wii timeout
    - [ ] Remove wii from registry on timeout
- [x] Turn replay processor into a GenServer
- [ ] Implement retries for failing API requests
- [ ] Gracefully handle wii connection failure
- [ ] Add lots of debug logs for easier debugging