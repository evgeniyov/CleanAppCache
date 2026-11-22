## Summary

<!-- What does this change do, and why? Link the issue if there is one. -->

## Testing

<!-- How did you check it? Include your macOS version, Mac model and the screens you tested. -->

## Checklist

- [ ] `Scripts/verify.sh` passes locally
- [ ] Both `en.lproj` and `ru.lproj` include new or changed user-facing strings
- [ ] All file deletions use `DeletionService` or `TrashService` to check `PathGuard`. No direct `FileManager` calls delete files
- [ ] New or updated tests cover changes in behaviour
- [ ] The pull request includes screenshots for UI changes, in both themes if the change affects colours
