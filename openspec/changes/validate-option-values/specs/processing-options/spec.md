## ADDED Requirements

### Requirement: Validation checks each value, not only the rules between keys
`Options.validate/1` SHALL refuse a struct whose field holds a value that `parse/1` would refuse, with the same structured error. Thus every struct that `validate/1` accepts normalizes to a string that re-parses.

#### Scenario: An out-of-domain value on a hand-built struct
- **WHEN** `validate/1` receives `%Options{format: :peaks, peak_bits: 24}`, `%Options{format: :peaks, channels: 3}` or `%Options{format: :peaks, peak_count: 0}`
- **THEN** it returns an error naming the segment, as `parse/1` does for the same value

#### Scenario: Accepted structs re-parse
- **WHEN** any struct passes `validate/1`
- **THEN** `parse(normalize(struct))` succeeds and normalizes to the same string
