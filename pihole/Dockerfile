# =============================================================================
# Dockerfile.pihole
# Wraps the official pihole/pihole image with a custom entrypoint that:
#   1. Sets the default gateway (macvlan gives no gateway by default)
#   2. Hands off to the official Pi-hole entrypoint
# =============================================================================

FROM pihole/pihole:latest

# ── Gateway-fixup wrapper ─────────────────────────────────────────────────────
# iproute2 may already be present in the pihole image; install anyway to be safe
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*


COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Official pihole entrypoint is /s6-init (s6 supervisor).
# Our wrapper sets the gateway then exec's into it.
ENTRYPOINT ["/entrypoint.sh"]
