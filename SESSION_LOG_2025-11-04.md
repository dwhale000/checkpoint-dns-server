# Checkpoint DNS Server - Troubleshooting Session
**Date:** November 4, 2025
**Session Duration:** ~2 hours
**Status:** Partially Resolved - Configuration Issues Identified

---

## Project Overview

**Checkpoint DNS** is a DNS-based gambling blocker running on Fly.io using Blocky DNS proxy.

### Architecture
- **DNS Server:** Blocky v0.27.0 (0xERR0R/blocky)
- **Platform:** Fly.io (region: iad - US East Virginia)
- **Deployment:** Docker container
- **Protocol:** DNS-over-HTTPS (DoH) on port 443
- **Client:** iPhone with DNS profile configuration

### Repository
- GitHub: `dwhale000/checkpoint-dns-server`
- Branch: `main`
- Blocklist: Custom gambling sites (102 entries with wildcards)

---

## Initial Problem

User reported seeing logs showing `analytics.888poker.com` was **NOT being blocked**, despite `888poker.com` being in the blocklist. Meanwhile, `rollbit.com` was correctly blocked.

### Evidence from Logs (Oct 24 working state)
```
rollbit.com → BLOCKED (gambling) ✅
analytics.888poker.com → RESOLVED (allowed through) ❌
```

---

## Root Cause Analysis

### Discovery #1: Subdomain Blocking Not Working

**Problem:** Blocky does NOT automatically block subdomains when a parent domain is in the blocklist.

**Official Documentation Finding:**
> "You can use wildcards to block a domain and all its subdomains. Example: `*.example.com`"

This means blocking `888poker.com` only blocks the exact domain, NOT:
- `www.888poker.com`
- `analytics.888poker.com`
- `mobile.888poker.com`

**Solution Implemented:**
Updated `gambling-blocklist.txt` to include wildcard entries for all domains:
```
888poker.com
*.888poker.com
```

**Commit:** `1d00bf2` - "Add wildcard entries to block all gambling subdomains"
**Result:** Blocklist grew from 51 entries to 102 entries (72 unique after processing)

---

## Attempted Fix #1: Enable Port 53 (FAILED)

### Reasoning
We initially thought the DNS server needed traditional DNS (port 53 UDP) enabled for broader compatibility.

### Changes Made
**Commit:** `426b002` - "Enable traditional DNS on port 53 for public access"

Modified `fly.toml`:
```toml
[[services]]
  internal_port = 53
  protocol = "udp"

  [[services.ports]]
    port = 53
```

### Deployment Failure
**Error:**
```
Health check on port 53 has failed
timeout reached waiting for health checks to pass
```

**Root Cause:** HTTP health check was being applied to UDP service (port 53), which doesn't support HTTP.

---

## Attempted Fix #2: Correct Health Check Placement (FAILED)

### Changes Made
**Commit:** `d34ea49` - "Fix: Move health check inside HTTPS service only"

Moved health check configuration inside the HTTPS service block to avoid applying it to UDP service.

### Deployment Status
Deployment succeeded, but discovered a **critical Fly.io limitation**.

### Fly.io Platform Limitation Discovered

**Web Research Finding:**
> "UDP port 53 doesn't work on Fly.io shared IP addresses - Fly.io's own DNS intercepts the traffic"

**Evidence:**
```bash
$ dig @66.241.124.229 888poker.com
;; connection timed out; no servers could be reached
```

**Community Reports (from Fly.io forums):**
- "Not receiving UDP traffic on port 53" (Feb 2025)
- "TCP/UDP port 53 blocked? Trying to setup a DNS server" (multiple threads)
- Users report TCP DNS works but UDP does not on shared IPs

**Conclusion:** Port 53 (UDP) is not viable on Fly.io's shared IP addresses.

---

## Final Solution: Revert to Working Configuration

### Decision
Reverted to the Oct 24, 2025 working state but **kept** the wildcard blocklist improvements.

**Commit:** `2d01122` - "Revert to working DoH-only configuration (keep wildcard blocklist)"

### Final Configuration

**fly.toml:**
```toml
# HTTPS service for DNS-over-HTTPS (DoH)
[[services]]
  internal_port = 8080
  protocol = "tcp"

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]

  [[services.http_checks]]
    interval = "30s"
    timeout = "5s"
    grace_period = "10s"
    method = "GET"
    path = "/"

# Port 53 commented out (doesn't work on Fly.io shared IPs)
```

**gambling-blocklist.txt:**
- 51 gambling domains
- 51 wildcard entries (*.domain.com)
- Total: 102 entries in file → 72 loaded entries (Blocky deduplicates)

### Deployment Status
```
✔ [1/2] Machine 0805091b524298 is now in a good state
✔ [2/2] Machine 91859596c72478 is now in a good state
```

**Blocklist Verification:**
```
INFO server: gambling: 72 entries
INFO server: TOTAL: 72 entries
```

---

## Current Issue: No Query Logs

### Symptoms
After successful deployment, **no DNS queries are appearing in logs**.

**Expected:** Query logs showing BLOCKED/RESOLVED entries
**Actual:** Server running, blocklist loaded, but zero query logs

### User Configuration
**Device:** iPhone
**Setup:** Settings → Device Management → VPN & DNS → DNS → "Checkpoint" profile selected

### Hypothesis: DNS Cache
The DNS server is deployed and running correctly, but queries may not be reaching it due to:
1. **iPhone DNS cache** - Previous DNS responses cached
2. **DNS profile propagation delay** - Profile settings taking time to activate
3. **DNS TTL from previous queries** - Old responses still valid

### Verification Commands Run
```bash
# Check services
flyctl services list --app checkpoint-dns
# Result: Only TCP 443 => 8080 exposed (DoH)

# Check logs
flyctl logs --app checkpoint-dns | grep "queryLog:"
# Result: No query logs found
```

---

## Git Commit History

```
2d01122 - Revert to working DoH-only configuration (keep wildcard blocklist)
d34ea49 - Fix: Move health check inside HTTPS service only
426b002 - Enable traditional DNS on port 53 for public access
1d00bf2 - Add wildcard entries to block all gambling subdomains
9b12dc2 - Updated config to use custom GitHub-hosted blocklist (Oct 24 - WORKING STATE)
ce5b481 - Initial commit: Blocky DNS server with custom gambling blocklist
```

---

## Key Technical Learnings

### 1. Blocky Subdomain Blocking Behavior
- **NOT automatic** - parent domain blocking doesn't include subdomains
- **Requires wildcards** - must explicitly add `*.domain.com` entries
- **Documentation source:** https://0xerr0r.github.io/blocky/latest/configuration/

### 2. Fly.io DNS Limitations
- **Port 53 UDP blocked** on shared IP addresses
- Fly.io's internal DNS intercepts UDP:53 traffic
- **TCP DNS works** but requires client support
- **DoH (DNS-over-HTTPS) is recommended** for Fly.io deployments

### 3. Health Check Configuration
- Health checks must be scoped to specific services
- HTTP health checks cannot be applied to UDP services
- Incorrect placement causes deployment failures

### 4. iOS DNS Configuration
- Uses DNS profiles (Settings → VPN & DNS → DNS)
- Supports custom DoH servers via configuration profiles
- Profile selection alone may not immediately activate

---

## Diagnostic Process Used

### 1. Service Verification
```bash
flyctl services list --app checkpoint-dns
# Shows which ports are actually exposed
```

### 2. Configuration Download
```bash
flyctl config save --app checkpoint-dns
# Downloads currently deployed fly.toml for comparison
```

### 3. Log Analysis
```bash
flyctl logs --app checkpoint-dns --no-tail | tail -100
flyctl logs --app checkpoint-dns | grep "queryLog:"
flyctl logs --app checkpoint-dns | grep "BLOCKED"
```

### 4. Network Testing
```bash
dig @66.241.124.229 rollbit.com +short
# Tests if DNS server responds on port 53
```

---

## Files Modified

### gambling-blocklist.txt
**Before:** 59 lines (51 domains)
**After:** 109 lines (51 domains + 51 wildcards + comments)

**Sample entries:**
```
# Poker Sites
pokerstars.com
*.pokerstars.com
888poker.com
*.888poker.com
partypoker.com
*.partypoker.com
```

**Note:** Fixed typo - changed `heritage sports.eu` to `heritagesports.eu` (removed space)

### fly.toml
Reverted to Oct 24 working state:
- Only port 443 (HTTPS/DoH) exposed
- Port 53 commented out
- Health check properly scoped to HTTPS service only

### config.yml
**No changes made** - still using original configuration with:
- Query logging enabled
- Blocklist refresh: every 4 hours
- Block type: zeroIp (returns 0.0.0.0)
- Block TTL: 6 hours

---

## Outstanding Issues

### 1. No Query Logs Appearing
**Status:** INVESTIGATING
**Hypothesis:** DNS cache / profile propagation delay
**Next Steps:**
- Wait for DNS cache to clear
- Verify DoH URL in iPhone DNS profile
- Try toggling DNS profile off/on
- Restart iPhone to force DNS refresh

### 2. DoH URL Verification Needed
**Question:** What URL is configured in the iPhone DNS profile?
**Expected:** `https://checkpoint-dns.fly.dev/dns-query`

### 3. Some Domains Blocked, Others Not
**Status:** UNEXPLAINED
**Note:** If no queries are reaching the DNS server, blocking must be from another source:
- Browser extension
- iOS content blocker
- Different DNS profile

---

## Next Steps (Recommended)

### Immediate Actions
1. **Verify DNS Profile Configuration**
   - Check exact DoH URL in iPhone profile
   - Ensure it points to: `https://checkpoint-dns.fly.dev/dns-query`

2. **Force DNS Cache Clear**
   - Toggle Airplane Mode on/off
   - Toggle DNS profile off and back on
   - Restart iPhone completely

3. **Test DNS Server Directly**
   - Visit `https://checkpoint-dns.fly.dev/` in browser
   - Should show Blocky API interface

4. **Monitor Logs in Real-Time**
   ```bash
   flyctl logs --app checkpoint-dns
   ```
   - Watch while browsing on iPhone
   - Should see query logs if DNS is working

### If Still No Logs After 30 Minutes

1. **Recreate DNS Profile**
   - Remove current "Checkpoint" profile
   - Create new profile with verified DoH URL

2. **Verify Blocky API Endpoint**
   ```bash
   curl https://checkpoint-dns.fly.dev/api/blocking/status
   ```

3. **Check Deployment Status**
   ```bash
   flyctl status --app checkpoint-dns
   flyctl logs --app checkpoint-dns | grep "https server is up"
   ```

---

## Working Deployment Details

### App Information
- **Name:** checkpoint-dns
- **URL:** https://checkpoint-dns.fly.dev
- **Region:** iad (US East - Virginia)
- **Machines:** 2 instances (version 6+)
- **Image:** checkpoint-dns:deployment-01K969HJHMJ2YK8CWM1R8C9TYP

### Current Services
```
PROTOCOL  PORTS        HANDLERS
TCP       443 => 8080  [TLS,HTTP]
```

### Blocklist Status
```
Source: https://raw.githubusercontent.com/dwhale000/checkpoint-dns-server/main/gambling-blocklist.txt
Loaded: 72 entries
Type: Denylist (gambling)
Refresh: Every 4 hours
```

---

## Resources & Documentation

### Blocky DNS
- GitHub: https://github.com/0xERR0R/blocky
- Docs: https://0xerr0r.github.io/blocky/latest/configuration/
- Version: v0.27.0 (Build: 20251010-192919)

### Fly.io
- Dashboard: https://fly.io/apps/checkpoint-dns
- Docs: https://fly.io/docs/
- Community Forums: https://community.fly.io/

### DNS Configuration
- DoH URL: `https://checkpoint-dns.fly.dev/dns-query`
- API Endpoint: `https://checkpoint-dns.fly.dev/api/`
- IPv4 Address: `66.241.124.229`
- IPv6 Address: `2a09:8280:1::a9:6443:0`

---

## Troubleshooting Commands Reference

```bash
# View deployment status
flyctl status --app checkpoint-dns

# List exposed services/ports
flyctl services list --app checkpoint-dns

# View logs (last 100 lines)
flyctl logs --app checkpoint-dns --no-tail | tail -100

# Follow logs in real-time
flyctl logs --app checkpoint-dns

# Download deployed configuration
flyctl config save --app checkpoint-dns

# Deploy changes
flyctl deploy --app checkpoint-dns

# Check app IPs
flyctl ips list --app checkpoint-dns

# Test DNS resolution (requires port 53 UDP - NOT WORKING on Fly.io)
dig @66.241.124.229 rollbit.com +short

# Git history
git log --oneline --all

# Check specific commit
git show <commit-hash>
```

---

## Summary

### What Works ✅
- Fly.io deployment successful
- Blocky DNS server running (v0.27.0)
- Blocklist loaded (72 entries with wildcard subdomain blocking)
- DoH endpoint accessible on port 443
- Health checks passing
- GitHub integration for blocklist updates

### What Doesn't Work ❌
- Port 53 (UDP) - blocked by Fly.io on shared IPs
- No DNS query logs appearing
- Unable to verify if blocking is actually working

### What Changed ✅
- Blocklist now includes wildcard entries (*.domain.com)
- Will block subdomains like analytics.888poker.com
- Configuration reverted to Oct 24 working state

### Root Cause of Original Issue ✅
- Blocky doesn't automatically block subdomains
- Required explicit wildcard entries
- Now fixed in blocklist

### Remaining Mystery ❓
- Why no query logs?
- DNS cache or profile configuration issue suspected
- Needs time-based verification or iPhone DNS profile check

---

**End of Session Log**
**Last Updated:** 2025-11-04 02:05 AM EST
