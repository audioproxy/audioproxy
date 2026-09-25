## 1. Validation

- [ ] 1.1 Make one definition of each field's domain that `parse/1` and `validate/1` both use
- [ ] 1.2 Check every field's value in `validate/1`, returning the error `parse/1` returns for the same value
- [ ] 1.3 Test the three structs in the proposal's table

## 2. Property

- [ ] 2.1 Generate structs directly, not through `parse/1`, and assert that `validate/1` accepts a struct only if `normalize/1` of it re-parses to the same string
