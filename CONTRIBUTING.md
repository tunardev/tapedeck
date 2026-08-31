# Contributing

I would love for your contributions, here are the guidelines I would like you to follow.

- [Commit Messages](#commit-messages)

# Guidelines

## Commit Messages

Just suit to [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) with these enums:

- `feat`
- `docs`
- `refactor`
- `style`
- `chore`
- `build`
- `fix`
- `revert`

then commit

```shell
$ git commit -m 'fix: my fix'
```

# Setup the Project

first of all, fork this repository from `github`
then clone your forked repository.

```shell
$ git clone https://github.com/<your_github_username>/nightjar
$ cd nightjar
```

Create a branch for your contribute or use `main` branch

```shell
$ git branch -m 'my-fix-name'
```

Your repository setup ready, let's setup environment.

This is a Rust project, you'll need Rust installed. The toolchain is pinned by `rust-toolchain.toml`.

```shell
$ curl https://sh.rustup.rs -sSf | sh
```

Build the workspace and run the checks.

```shell
$ cargo build --workspace
$ cargo test --workspace --lib --tests
$ cargo clippy --workspace --all-targets -- -D warnings
$ cargo fmt --check
```

Now you are ready to development make your code update.

# Pull Request

You don't need to suit a Pull request template just add a description.

```shell
$ git add <my-changed-files>
$ git commit -m '<type>: <description>'
$ git push origin <your-branch>
```

Now go your forked repository in `github`.<br>
[Open a pull request from your repository](https://docs.github.com/en/github/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request) then wait me!
