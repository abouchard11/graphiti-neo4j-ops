# Contributing

Thanks for improving Graphiti Neo4j Ops.

1. Fork the repository and create a focused branch.
2. Never commit `.env`, database dumps, logs, or machine-specific paths.
3. Run the local checks:

   ```bash
   bash tests/test-scripts.sh
   docker compose --env-file .env.example config --quiet
   xmllint --noout scripts/launchd/*.plist.template
   shellcheck scripts/*.sh tests/*.sh
   ```

4. Open a pull request describing the failure mode, the change, and how it was
   verified.

Changes to scripts should include a behavioral regression test. Changes to
Graphiti itself belong in the upstream
[getzep/graphiti](https://github.com/getzep/graphiti) repository.
