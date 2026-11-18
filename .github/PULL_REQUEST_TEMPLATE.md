## Summary

<!-- What does this change do, and why? Link the issue if there is one. -->

## Testing

<!-- How you checked it: macOS version, Mac model, screens you exercised. -->

## Checklist

- [ ] `Scripts/verify.sh` passes locally
- [ ] New or changed user-facing strings are added to both `en.lproj` and `ru.lproj`
- [ ] Any file deletion goes through `DeletionService` / `TrashService` (never a direct `FileManager` call), so `PathGuard` is checked
- [ ] Tests are added or updated for changed behaviour
- [ ] Screenshots are attached for UI changes (light and dark if the change affects colours)
