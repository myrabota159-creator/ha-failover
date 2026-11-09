# Primary side (temporary)

Until the **HA Failover Primary** add-on exists (roadmap step 2), the standby talks to the primary over SSH
with a forced command. Nothing else can be run with the standby's key.

1. Install an SSH add-on on the primary that supports `authorized_keys` options and `sudo`.
2. Copy `export.sh` to `/homeassistant/.replica/export.sh` and `export.conf.example` to
   `/homeassistant/.replica/export.conf`, then edit `export.conf`.
3. Start the standby add-on once: its log prints the public key.
4. Add the key on the primary with the forced command:

   ```
   command="sudo /bin/bash /homeassistant/.replica/export.sh \"${SSH_ORIGINAL_COMMAND:-export}\"",restrict ssh-ed25519 AAAA... ha-failover-standby
   ```

5. On the standby run `return-to-pi-health`: it must show the health JSON and a refusal for an unknown request.

`export` reads the configuration and add-on settings and never changes anything on the primary.
