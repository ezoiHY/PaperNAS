# Security

Paper NAS is intended for a personal workspace reachable through HTTPS or a trusted private network. Every authorized device can access and modify the whole workspace. It is not a public multi-tenant service.

Do not place access keys, provider keys, device tokens, connection JSON, `.env`, state directories, databases, or backups in Git, logs, issues, or screenshots. Rotate/revoke a credential if it has been exposed. Provider keys are server-only; browser device credentials last for the tab session and Mac credentials are stored in Keychain.

Keep PostgreSQL private, restrict state-directory permissions, back up database and files together, and use a reverse proxy or network access controls suitable for your environment. Imported files and remote URLs are untrusted. Private source hosts require explicit configuration; deployments accepting untrusted users also require egress isolation and additional abuse controls beyond this release.

For a vulnerability, use [GitHub's private vulnerability report](https://github.com/ezoiHY/PaperNAS/security/advisories/new), which is enabled for this repository. Do not create a public issue containing an exploit, credential, or personal data. If private reporting is unavailable, open a minimal issue asking for a private contact without including sensitive details.

Before a public release, maintainers should review dependency updates and the source audit. The local audit is a practical check, not a guarantee that no sensitive information exists.
