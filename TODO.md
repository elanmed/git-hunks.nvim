# TODO

- [ ] Support `diff_type` for highlights

## Notes:

- Highlights: do I want to show other kinds of diffs via highlight in the current file?
  - Yes, but only make sense to be able to reset diffs if the base file is the working tree

## Diffview

- Support all of the following

| vs ->        | index                                  | head                                             | upstream                                                    | mergebase                                                                          |
| ------------ | -------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| **worktree** | `cat filename` vs `git show :filename` | `cat filename` vs `git show HEAD:filename`       | `cat filename` vs `git show origin/main:filename`           | `cat filename` vs `git show $(git merge-base HEAD origin/main):filename`           |
| **index**    | —                                      | `git show :filename` vs `git show HEAD:filename` | `git show :filename` vs `git show origin/main:filename`     | `git show :filename` vs `git show $(git merge-base HEAD origin/main):filename`     |
| **head**     |                                        | —                                                | `git show HEAD:filename` vs `git show origin/main:filename` | `git show HEAD:filename` vs `git show $(git merge-base HEAD origin/main):filename` |
| **upstream** |                                        |                                                  | —                                                           |                                                                                    |

| vs ->        | index                  | head                            | upstream                                    | mergebase                                                          |
| ------------ | ---------------------- | ------------------------------- | ------------------------------------------- | ------------------------------------------------------------------ |
| **worktree** | `git diff --name-only` | `git diff --name-only HEAD`     | `git diff --name-only origin/main`          | `git diff --name-only $(git merge-base HEAD origin/main)`          |
| **index**    | —                      | `git diff --name-only --cached` | `git diff --name-only --cached origin/main` | `git diff --name-only --cached $(git merge-base HEAD origin/main)` |
| **head**     |                        | —                               | `git diff --name-only HEAD origin/main`     | `git diff --name-only origin/main...HEAD`                          |
| **upstream** |                        |                                 | —                                           |                                                                    |
