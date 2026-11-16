import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_aws.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Cloud import (3.0): how each provider is shown, what its Connect step
/// asks for, and how to make the read-only token it needs.

/// The provider's own name (a brand, never translated).
String cloudProviderName(CloudProvider p) => switch (p) {
      CloudProvider.aws => 'AWS EC2',
      CloudProvider.digitalocean => 'DigitalOcean',
      CloudProvider.hetzner => 'Hetzner Cloud',
      CloudProvider.azure => 'Azure',
      CloudProvider.tailscale => 'Tailscale',
      CloudProvider.proxmox => 'Proxmox VE',
    };

/// The two or three letters on the provider's tile.
String cloudProviderMark(CloudProvider p) => switch (p) {
      CloudProvider.aws => 'AWS',
      CloudProvider.digitalocean => 'DO',
      CloudProvider.hetzner => 'HZ',
      CloudProvider.azure => 'AZ',
      CloudProvider.tailscale => 'TS',
      CloudProvider.proxmox => 'PVE',
    };

String cloudProviderBlurb(AppLocalizations l10n, CloudProvider p) => switch (p) {
      CloudProvider.aws => l10n.cloudImpAwsDesc,
      CloudProvider.digitalocean => l10n.cloudImpDoDesc,
      CloudProvider.hetzner => l10n.cloudImpHetznerDesc,
      CloudProvider.azure => l10n.cloudImpAzureDesc,
      CloudProvider.tailscale => l10n.cloudImpTailscaleDesc,
      CloudProvider.proxmox => l10n.cloudImpProxmoxDesc,
    };

/// What the token must be, one line under the fields.
String cloudTokenCaption(AppLocalizations l10n, CloudProvider p) => switch (p) {
      CloudProvider.aws => l10n.cloudImpTokenAws,
      CloudProvider.digitalocean => l10n.cloudImpTokenDo,
      CloudProvider.hetzner => l10n.cloudImpTokenHetzner,
      CloudProvider.azure => l10n.cloudImpTokenAzure,
      CloudProvider.tailscale => l10n.cloudImpTokenTailscale,
      CloudProvider.proxmox => l10n.cloudImpTokenProxmox,
    };

/// One field of a provider's Connect step.
class CloudFieldSpec {
  const CloudFieldSpec(this.key, this.label, {this.secret = false, this.optional = false, this.placeholder, this.help});

  /// A [CloudField] name.
  final String key;
  final String label;
  final bool secret;
  final bool optional;
  final String? placeholder;
  final String? help;
}

List<CloudFieldSpec> cloudFieldsOf(AppLocalizations l10n, CloudProvider p) => switch (p) {
      CloudProvider.aws => [
          CloudFieldSpec(CloudField.keyId, l10n.cloudImpAccessKeyId, placeholder: 'AKIA...'),
          CloudFieldSpec(CloudField.secret, l10n.cloudImpSecretKey, secret: true),
          CloudFieldSpec(CloudField.session, l10n.cloudImpSessionToken, secret: true, optional: true, help: l10n.cloudImpSessionTokenHelp),
          CloudFieldSpec(CloudField.regions, l10n.cloudImpRegions,
              optional: true, placeholder: 'us-east-1 eu-west-1', help: l10n.cloudImpRegionsHelp),
        ],
      CloudProvider.digitalocean => [
          CloudFieldSpec(CloudField.token, l10n.cloudImpToken, secret: true, placeholder: 'dop_v1_...'),
        ],
      CloudProvider.hetzner => [
          CloudFieldSpec(CloudField.token, l10n.cloudImpToken, secret: true),
        ],
      CloudProvider.azure => [
          CloudFieldSpec(CloudField.tenant, l10n.cloudImpTenant, optional: true, placeholder: '00000000-0000-...'),
          CloudFieldSpec(CloudField.clientId, l10n.cloudImpClientId, optional: true, placeholder: '00000000-0000-...'),
          CloudFieldSpec(CloudField.secret, l10n.cloudImpClientSecret, secret: true, help: l10n.cloudImpClientSecretHelp),
          CloudFieldSpec(CloudField.subscription, l10n.cloudImpSubscription,
              optional: true, placeholder: '00000000-0000-...', help: l10n.cloudImpSubscriptionHelp),
        ],
      CloudProvider.tailscale => [
          CloudFieldSpec(CloudField.server, l10n.cloudFieldControlServer,
              optional: true, placeholder: 'https://headscale.example.com', help: l10n.cloudFieldControlServerHelp),
          CloudFieldSpec(CloudField.token, l10n.cloudImpToken, secret: true, placeholder: 'tskey-client-... / tskey-api-...'),
        ],
      CloudProvider.proxmox => [
          CloudFieldSpec(CloudField.url, l10n.cloudImpProxmoxUrl, placeholder: 'https://10.0.0.10:8006', help: l10n.cloudImpProxmoxUrlHelp),
          CloudFieldSpec(CloudField.token, l10n.cloudImpProxmoxToken, secret: true, placeholder: 'root@pam!zestssh=...'),
        ],
    };

/// A step of "How to make one", with something to copy where there is one.
typedef CloudHowToStep = ({String text, String? copy});

/// The Proxmox commands that make a token that can only read.
const kProxmoxTokenCommands = 'pveum user token add root@pam zestssh --privsep 1\n'
    "pveum acl modify / --tokens 'root@pam!zestssh' --roles PVEAuditor";

/// The Azure commands: a service principal that can only read, or a
/// one-hour access token.
const kAzureReaderCommand = 'az ad sp create-for-rbac --name zestssh-import --role Reader --scopes /subscriptions/<subscription-id>';
const kAzureTokenCommand = 'az account get-access-token --resource https://management.azure.com --query accessToken -o tsv';

List<CloudHowToStep> cloudHowTo(AppLocalizations l10n, CloudProvider p) => switch (p) {
      CloudProvider.aws => [(text: l10n.cloudImpHowAws, copy: kAwsReadOnlyPolicy)],
      CloudProvider.digitalocean => [(text: l10n.cloudImpHowDo, copy: null)],
      CloudProvider.hetzner => [(text: l10n.cloudImpHowHetzner, copy: null)],
      CloudProvider.azure => [
          (text: l10n.cloudImpHowAzure, copy: kAzureReaderCommand),
          (text: l10n.cloudImpHowAzureToken, copy: kAzureTokenCommand),
        ],
      CloudProvider.tailscale => [(text: l10n.cloudImpHowTailscale, copy: null)],
      CloudProvider.proxmox => [
          (text: l10n.cloudImpHowProxmox, copy: kProxmoxTokenCommands),
          (text: l10n.cloudImpHowProxmoxAgent, copy: null),
        ],
    };

/// The sign-in name the provider's machines usually take, as a hint where
/// the person picks a key.
String? cloudSignInHint(AppLocalizations l10n, CloudProvider p) => switch (p) {
      CloudProvider.digitalocean || CloudProvider.hetzner => l10n.cloudImpSignInHintRoot(cloudProviderName(p)),
      CloudProvider.azure => l10n.cloudImpSignInHintAzure,
      CloudProvider.aws => l10n.cloudImpSignInHintAws,
      CloudProvider.tailscale || CloudProvider.proxmox => null,
    };

/// A failure, in words, for [provider].
String cloudErrorMessage(AppLocalizations l10n, CloudErrorKind kind, CloudProvider provider) {
  final name = cloudProviderName(provider);
  return switch (kind) {
    CloudErrorKind.signIn => l10n.cloudErrSignIn(name),
    CloudErrorKind.notAllowed => l10n.cloudErrNotAllowed(name),
    CloudErrorKind.notFound => l10n.cloudErrNotFound(name),
    CloudErrorKind.tooMany => l10n.cloudErrTooMany(name),
    CloudErrorKind.offline => l10n.cloudErrOffline(name),
    CloudErrorKind.timeout => l10n.cloudErrTimeout(name),
    CloudErrorKind.certificate => l10n.cloudErrCertificate(name),
    CloudErrorKind.certificateChanged => l10n.cloudErrCertificateChanged,
    CloudErrorKind.server => l10n.cloudErrServer(name),
    CloudErrorKind.answer => l10n.cloudErrAnswer(name),
  };
}
