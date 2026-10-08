---
title: "NAT traversal field test: sending photos from a 5G phone to a computer at home"
description: "Can a phone on 4G/5G send photos to a computer behind a home router? A NAT traversal field test with iroh and QUIC, comparing direct and relayed paths."
date: 2026-09-16
tags: [networking, engineering]
lang: en
draft: false
---

P-Pass moves the photos on your phone to a computer at home. When you're home, that part is easy: the phone and the computer are on the same Wi-Fi network and the transfer stays on the LAN.

It gets harder once you leave the house. The phone is on 4G/5G, the computer sits behind the home router, and neither side has an address the other can reach directly. Family members ask the simple version: "Can my photos still back up while I'm out?" Developers ask a sharper one. The cellular side is behind carrier-grade NAT (CGNAT), where the carrier shares one public IPv4 address across many subscribers, and the home broadband connection adds its own router NAT. Can the two devices still connect directly? And when they can't, how slow is the relay?

We ran these tests in late July 2026, when the project had just started and we were still checking whether the technical approach would hold up. Each phone-to-home scenario was 20 connections of 100MB each. Along the way, a single line of code that detected the IP version made us draw a conclusion that was backwards, and we had to walk it back.

## The transport stack

P-Pass uses iroh for its transport layer, which runs on QUIC with TLS 1.3 encryption. When two devices connect, they first rendezvous through a relay server, where each side shares the addresses it has observed for itself. Then it tries hole punching, and if that works, traffic moves to the direct path. If hole punching fails, data goes through public relays operated by number 0, the team that maintains iroh. The relay forwards encrypted QUIC data. It can't see photo content and doesn't write anything to disk.

So "can I send photos home?" is really two questions:

1. Can the devices connect at all? Yes, as long as the relay is reachable.
2. Does the connection go direct or through the relay? That decides the speed, and whether the connection depends on third-party infrastructure.

We wanted the real-world answer to the second question.

## How we tested

The test setup was two small programs. On the home computer, a command-line listener starts up and prints its NodeId and a connection ticket:

```bash
cargo run -- listen
```

On the phone, a test app takes the ticket. You tap "Connect + Send 100MB" once and it runs 20 rounds in a row. Each round writes one JSONL line with the selected path (lan / direct / relay), IP version, connect time, throughput, and any error. A raw line looks like this:

```json
{"type":"transfer","attempt":2,"path":"relay","ipver":"v6","connect_ms":420,"throughput_mbps":7.91,"error":"","elapsed_s":166,"screen_on":"true","charging":"false"}
```

Every scenario got at least 20 connection attempts, each sending 100MB. We set pass/fail thresholds before testing. On the same Wi-Fi network, the direct connection rate had to be 100%. Between home broadband and cellular, 70% or higher was a pass, 50% to 70% meant wait and see, and below 50% meant going back to check the iroh configuration and the network environment.

Three kinds of devices took part:

- Home broadband: the computer at home ran the listener. UPnP was off on the home router. The home-side setup was different between the first test and the retest, which we cover below.
- Cellular: a HarmonyOS phone dialing out over 5G with Wi-Fi turned off.
- Cloud servers: one in mainland China and one in Singapore, both with public IPv4, no NAT, and no IPv6. We used them to look at the cellular side and the home broadband side separately.

## Results

Here is the summary table. The path column shows direct rounds out of total rounds. Where we don't have per-round path records, the table says so.

| Dialer → listener | Rounds | Path | Connect time | Throughput |
|---|---|---|---|---|
| Phone on home Wi-Fi → home Mac | 20 | 20/20 direct (18 rounds IPv6, 2 rounds IPv4 LAN) | n/a | 29.3–50.8 Mbps, mean 43.9 |
| 5G phone → home Mac (first test) | 20 | 0/20 direct, all 20 rounds completed via relay | P50 405ms, first round 1259ms | P50 11.3 Mbps (6.0–13.5) |
| 5G phone → home Mac (retest) | 20 | All 20 rounds completed; the 6 rounds the listener logged afterward were all IPv6 direct | n/a | 51.9–68.1 Mbps across the 6 logged rounds |
| 5G phone → cloud server in mainland China | 20 | 20 rounds completed; the 14 rounds visible in logs were all IPv4 direct | 34–49ms (one round 1072ms) | 18.4–47.7 Mbps |
| 5G phone → Singapore cloud server | n/a | Connected, but the 100MB transfer stalled partway and timed out; 0 completed | n/a | n/a |
| Cloud server in mainland China → home Mac | 5 | Relay on round 1, IPv4 direct from round 2 | Direct 11–13ms | About 3.2 Mbps (capped by the server's 3 Mbps outbound limit) |
| Singapore cloud server → home Mac | 5 | Relay on round 1, IPv4 direct from round 2 | Direct 154–190ms | 12–21 Mbps |

A few notes on the table.

For the home Wi-Fi row, the test tool labeled the path as direct. The tool defines lan as "selected path RTT under 500 microseconds," and Wi-Fi RTT is in the milliseconds, so it never gets under that threshold. The peer addresses were `192.168.1.x` and IPv6 addresses under the same /64 prefix as the home connection, so the traffic never left the LAN. iroh also preferred IPv6 on the same Wi-Fi network: 18 of the 20 rounds used global IPv6 addresses, including two different suffixes produced by the phone's privacy address rotation. IPv6 and IPv4 rounds ran at the same speed. The two IPv4 rounds came in at 45.1 and 40.0 Mbps.

The 5G retest row is worded awkwardly because the listener wasn't recording per-transfer paths yet during the retest. The listener logs show all 20 rounds of 100MB completed with no stalls, 2GB in about 9 minutes. We got the path data afterward by switching to a listener that logs its own transfers and dialing a few more rounds. So we can only say "20 rounds completed," and the evidence for direct connections comes from the 6 rounds after that.

Neither cloud server has NAT, so dialing them from cellular involves no hole punching. Those two rows only answer whether outbound UDP on the cellular side is restricted. For the server in mainland China, it isn't. For the one outside the country, there's a problem, covered below.

## Where the 0/20 came from

The first 5G → home broadband test was 0/20 direct. By our thresholds, that's a fail.

We didn't call it a fail right away, because the home side wasn't a clean setup. The listener was running in a virtual machine on a Mac mini at home, with the VM in NAT mode. The host machine was running a local proxy in TUN mode, which took over all outbound IPv4, IPv6, and DNS traffic. The proxy routed relay registration to a node in the US West, so that 11.3 Mbps relay speed includes the cost of a detour through the US.

Our first explanation for the 0/20 went like this: the proxy corrupted how the home side determined its public IPv4 address, so IPv4 hole punching failed across the board, and the remaining IPv6 hole punching was blocked by the cellular inbound firewall. Everything fell back to the relay.

That explanation fell apart quickly. We decoded the ticket the home listener had actually used that day. These were the direct addresses in it:

```text
203.0.113.x:46xxx   # real public IPv4 of the home connection (masked), not affected by the proxy
192.168.64.3        # private address behind the VM's NAT
```

The IPv4 address was the real, clean WAN address. And the ticket had no IPv6 addresses at all. When we checked the VM on the home side, it only had a link-local address, and it had no working IPv6 connectivity.

So in that round of testing, the home side had no IPv6 path at all. "IPv6 hole punching was blocked by the firewall" described a path that didn't exist.

At that point we narrowed the suspects down to three, in order of likelihood:

1. The cellular NAT stacked on top of the home side's double NAT (router NAT plus VM NAT) made hole punching too hard.
2. The local proxy in TUN mode rewrote or rerouted some of the UDP packets used for hole punching.
3. UPnP was off on the router, which removed port mapping as a fallback.

To separate the variables, we ran two controlled comparisons.

The first looked at the cellular side. The same 5G phone dialed the cloud server in mainland China. All 20 rounds completed, and the 14 rounds visible in the logs were all IPv4 direct, at 18.4–47.7 Mbps. The server's receive count backs up the total number of completed rounds. This shows outbound UDP/QUIC on cellular in mainland China isn't restricted, which rules out "the carrier blocks UDP."

The second looked at the home broadband side. We set up a fresh Mac at home as the listener: no proxy, no VM, Wi-Fi only, a single layer of NAT, and UPnP still off. Decoding its ticket gave us a real public IPv4 address (not CGNAT; the NAT rewrote the external port from 41145 to 7446), a LAN address `192.168.1.x:41145`, and two global IPv6 addresses (`2xxx:xxxx::/64`). Then we dialed it from both cloud servers. Both the mainland China server and the Singapore server went through the relay on the first round and upgraded to IPv4 direct from the second round on.

So neither the home broadband connection nor the router was the problem, and hole punching worked with UPnP off.

Last, the same 5G phone dialed this clean Mac. Here is the raw line the listener recorded (address and NodeId masked):

```text
Received 100.0MB from <NodeId> (direct/v6 [2xxx:xxxx:…]:39595) 68.1/59.1/59.1/58.2/58.4/51.9 Mbps
```

The phone's global cellular IPv6 address connected straight to the home connection's global IPv6 address, with no relay involved, at 52–68 Mbps.

Looking back, the 0/20 in the first test came from two things at once. The VM had no global IPv6, which cut off the IPv6 path. Double NAT plus the proxy's TUN mode blocked the IPv4 path. With both paths gone, only the relay was left. The carrier and the router had nothing to do with it.

Same phone, same home, two ways of running the home side:

- Home side in a VM with the proxy on: 0/20 direct, relay P50 11.3 Mbps, 2GB in 26.8 minutes.
- Home side running directly on the host: IPv6 direct at 52–68 Mbps, 2GB in about 9 minutes.

As for IPv4 on the cellular side, our read is that it sits behind CGNAT. That is also why IPv6 matters so much when a 5G phone connects to home broadband: when both ends have global IPv6 addresses, they can reach each other directly without hole punching. This conclusion comes from reasoning over the comparisons above. We never measured the NAT type on the cellular side directly.

## Outbound UDP to other countries

The 5G → Singapore cloud server row shows a different problem. The connection succeeded and the small handshake packets got through, but the 100MB transfer stalled halfway and eventually timed out. Not a single transfer completed. The server log has only one line: `Client error: connection lost / timed out`.

In the other direction, the Singapore cloud server dialing home went direct from round 2, at 12–21 Mbps.

What we recorded is the asymmetry. Sending a large amount of UDP from cellular in mainland China to a server abroad didn't work. Dialing from abroad back to home broadband in mainland China worked fine. We have no evidence about which layer is doing the throttling, so we're only recording what we observed.

For the product, this affects where relays should be placed. iroh's relay protocol runs over TCP on port 443. In the first test, all 20 rounds through the relay completed with 0 failures, which shows outbound TCP to other countries works. Talking UDP directly to a peer abroad isn't workable, and the product has no need for it anyway. What matters is the quality of the leg between the phone and the relay.

## A measurement bug: `contains(":")`

We skipped part of the story above. After the first test, we had concluded that "IPv6 is the deciding factor for direct connections in mainland China." That was based on the `ipver` field in the logs, which said `v6` almost every time.

Then the home side reported that the VM had no global IPv6 at all. The listener had no IPv6, yet the logs said the connections used IPv6. Both couldn't be true.

The problem was the one line in the test app that detected the IP version. The old code checked the remote address of the selected path:

```kotlin
remoteAddr.contains(":")   // if it contains a colon, call it IPv6
```

The remote address is formatted as `ip:port`, so an IPv4 address also carries a port number and a colon. This line returned true for every address. That meant the `ipver` field was unreliable in every log produced by app versions v1 and v2, and every direct connection was recorded as v6. Going back through the logs from the first 5G test, all 20 lines say `"path":"relay"`, and every single one also says `v6` for `ipver`, while the home side in that round didn't have even one IPv6 address.

The fix strips the port before checking:

```kotlin
// "ip:port" always contains ':' — strip the port first; v6 iff the host part still has one
addr.substringBeforeLast(":").contains(":") -> "v6"
```

Version v3 also added a `remote` field that records the actual peer address as-is, so it can be checked by hand afterward.

The result: all IPv6 data from the v1/v2 period was thrown out, and "IPv6 is the deciding factor" was downgraded to an unverified hypothesis. What was later confirmed is a narrower version: when a 5G phone connects to home broadband, IPv6 is the path that can get a direct connection through. The evidence is the `direct/v6 [2xxx:xxxx:…]` line above, the first trustworthy IPv6 direct connection record in the whole project. Before that, we had been drawing conclusions from a check that was always true.

After this, we changed the test tooling in two ways. The listener now writes its own JSONL line for every transfer it receives, recording the peer NodeId, path, IP version, address, and throughput. iroh is equally observable from both ends, and logging only on the phone had been a shortcut in the tooling. With this change we no longer depend on exporting logs from the phone. The other change: every field that feeds into a conclusion has to be traceable to a raw address.

A similar-looking failure happened once more during testing. We ran the same ticket for two rounds and got 5/5 timeouts. It turned out the listener process had been killed much earlier, by mistake, by a timeout in the tooling that launched it. From the dialer's side, "the peer process is dead" and "the peer's relay link is down" look exactly the same: both show up as connect timed out.

## Rules we set for the product

In the review after testing, we turned these results into a few constraints on the product.

**The storage side must be reachable over global IPv6.** The desktop app has to run directly on the host machine, not inside a VM in NAT mode. In the first test's 0/20, the VM was what cut off the IPv6 path. A user who sets things up that way has blocked the fastest path themselves.

**"This machine has no global IPv6" is a top-level diagnostic item.** When a user asks why things are slow, this is the first thing we need to answer.

**The relay fallback must always be available.** IPv6 direct connections performed well in these tests, but they depend on conditions: both ends need global IPv6, and the home side has to be set up correctly. When those conditions aren't met, the relay is all that's left.

That last rule was confirmed again later in regression testing on a real device. In mid-September, we switched a different phone to 5G with Wi-Fi off, kept the home Mac on home Wi-Fi, and turned on debug logging in the desktop app. The connection came up but stayed on the relay the whole time, and this line showed up in the log about every 5 seconds:

```text
iroh::socket::remote_map::remote_state: connections are not good enough, triggering holepunching
```

The connection's `network_path` stayed at `Relay(aps1-1.relay.n0.iroh.link)` and never upgraded to direct. The transfer didn't hang. Several files went through the relay, including a video of about 220MB, just noticeably slower than a direct connection. The logs we have can't yet explain why hole punching didn't work this time. We didn't collect whether this phone had global IPv6 on that network.

So a 5G phone connecting to home broadband sometimes gets a direct connection and sometimes falls back to the relay, and the product has to treat both as normal.

The relay path also exposed a timeout problem. On the phone, connection setup and each individual request shared the same 15-second timeout, a value we had picked with LAN conditions in mind. Connection setup is slower over the relay to begin with. In another regression run, the phone was on a cellular hotspot, and while sending a 288MB video it reported `no response from the computer within 15000ms` three times in a row, then went into backoff and retry. The UI looked normal, but the photos just weren't moving. The desktop logs have no matching delivery records for those three attempts, so all we know for sure is that the phone ran out of its 15 seconds before the computer finished delivery. We can't yet tell whether the requests reached the computer at all. Splitting "connect timeout" and "request timeout" is the fix we've settled on, and we're waiting for a reproducible cellular window to verify it.

The other thing in progress is the relay itself. n0's public relays are assigned via anycast. During these tests, the home Mac was assigned a node in Germany, and the cloud server in mainland China timed out while connecting to a US West node, then switched to Germany. We're evaluating running our own relay in a region closer to mainland China, such as Singapore, so devices don't get assigned to nodes that are too far away. This is still at the planning stage.

## FAQ

### Can my phone connect to my home computer over 5G?

Yes. In our tests, every round of 5G to home broadband completed its transfer. When a direct connection didn't work, the relay carried it: in the first test, all 20 rounds went through the relay with 0 failures. Whether you get a direct connection depends on the network at both ends. With the home computer running directly on the host and global IPv6 at both ends, we measured IPv6 direct connections at 52–68 Mbps. With the home side in a virtual machine, we got 0/20 direct.

### How much slower is a relay connection than a direct connection?

With the same 5G phone and the same home, relay throughput had a P50 of 11.3 Mbps and 2GB took 26.8 minutes. IPv6 direct ran at 52–68 Mbps, and 2GB took about 9 minutes. That relay speed includes the cost of the home side's proxy detouring through the US West, and we haven't separately measured relay speed in a clean setup. For connect time, the relay path had a P50 of 405ms, with 1259ms on the first round.

### Does IPv6 help with remote access to a home computer?

Our read is that IPv4 on cellular networks sits behind CGNAT, which makes hole punching hard. With IPv6, both ends have global addresses and can reach each other directly without hole punching. The first trustworthy IPv6 direct connection we measured was exactly this case, a 5G phone to home broadband, at 52–68 Mbps. On the same Wi-Fi network, iroh also chose IPv6 in 18 of 20 rounds.

### What is the success rate of NAT hole punching?

It depends on the networks at both ends. Among the combinations we tested, the same Wi-Fi network was 20/20. The cloud servers in mainland China and Singapore both went through the relay on the first round when dialing home broadband and went direct from round 2, with 5/5 completed each. A 5G phone dialing a home side running in a VM was 0/20. In our observations, the first round goes through the relay so the two sides can rendezvous and exchange addresses, and direct connections start from the second connection.

### Can the relay server see my photos?

P-Pass's transport is built on QUIC and TLS 1.3, so the relay forwards encrypted data. It can't see photo content and doesn't write anything to disk. The relay handles the rendezvous when a connection is being set up, and forwards encrypted traffic from one end to the other when a direct connection isn't possible.
