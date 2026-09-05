# JOIN component catalogs

A catalog maps one observed Core or DAPI identity to exact executable bytes.
It is not a release profile and does not select a DevShard version. Host JOIN
uses an exact `chain_id`, Genesis, component version and commit match; it
refuses a missing or ambiguous record before SSH or other Host mutation.

Each catalog record is immutable by Git history and records an OCI digest and
binary SHA-256. The resolver binds the catalog-file SHA-256 into the generated
private Join Profile. A catalogue is local operator policy: JOIN never uploads
or publishes it.
