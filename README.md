# fw-zone-source-sync-from-urls

- Accepts a Firewalld zone name and a list of URLs (or a file containing URLs).
- Resolves each URL to its current IP addresses (IPv4 & IPv6).
- Compares the resolved set to the zone's current sources.
- Adds any new IPs and removes any IPs that are present in the zone but not in the resolved set.
- Only performs changes when there are actual diffs.
- Applies changes both to runtime (immediate) and --permanent (so they survive reboot), and reloads if permanent changes were made.
- Has a --dry-run mode which shows what would change without touching firewalld.
