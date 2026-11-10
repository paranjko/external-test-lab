# Retained producer fixture

`legacy-producer.tar.gz` is the unchanged output of the real legacy backup
script at revision `abf9bcf51bfdcaa133a1dc8f14b3bf5fb55c016f`.
Despite its retained filename, its bytes are an uncompressed tar archive.

SHA-256: `4ed38abb0ebb08d05943a97c538fdc899f4792c3c1df76330257a04ac1ed6f9b`.

The original generation record was checked before publishing this snapshot.
The generator created a temporary local data root with synthetic genesis,
accounts, mnemonics, and signer material. A temporary fake `ssh` command
supplied a locally assembled source tar and rejected unexpected calls. The
producer command was `validator-backup.sh create gdc-node1`. That name was a
fixture label, not a working node contacted by the test. The recorded output
hash matches the file here exactly.

The mnemonic and key fields are test-only data. They are not credentials for
an operational node and must not be reused for funded identities.

This establishes the origin and byte continuity of this particular fixture.
It does not qualify the required historical producer revision
`015501a6ac2fa4736d56b81eaa2c7722a6bd8908`, prove independent runtime key
derivation, or satisfy lab acceptance. The historical temporary-password
failure and the separate proposed producer correction remain unresolved.
Neither the archive nor its original manifest has been regenerated or
relabelled as qualified historical output.
