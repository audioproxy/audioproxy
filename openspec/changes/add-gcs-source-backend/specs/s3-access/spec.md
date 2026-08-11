## ADDED Requirements

### Requirement: GCS client profile
The S3 client SHALL support a `:gcs` profile assembled from the group-atomic `AP_GCS_*` group — `AP_GCS_KEY_ID` and `AP_GCS_SECRET` both-or-neither, `AP_GCS_ENDPOINT` defaulting to `https://storage.googleapis.com`, addressing defaulting to path-style — under which every facade operation (HEAD, presigned GET, streaming PUT, DELETE, ranged GET) signs with the GCS credentials against the GCS endpoint.

#### Scenario: Partial group refused at boot
- **WHEN** `AP_GCS_KEY_ID` is set without `AP_GCS_SECRET`
- **THEN** boot aborts naming the incomplete group

#### Scenario: Profiles are independent
- **WHEN** the shared `AWS_*` group points at one provider and `AP_GCS_*` at another
- **THEN** `s3://` sources sign under the shared profile and `gcs://` sources under the GCS profile, in the same running proxy

#### Scenario: Endpoint override
- **WHEN** `AP_GCS_ENDPOINT` names a custom origin
- **THEN** all GCS-profile requests and presigned URLs address that origin
