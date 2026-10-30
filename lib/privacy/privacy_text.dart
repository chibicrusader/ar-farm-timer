/// The privacy notice, shared by the in-app Privacy page and (by test)
/// checked against the static web/privacy.html.
library;

const privacyEmail = 'chibicrusader.business@gmail.com';
const privacyUrl = 'https://artimer.win/privacy.html';
const privacyTitle = 'Privacy Notice: AR Farm Timer';
const privacyUpdated = 'Last updated: October 29, 2026';

/// Shown in Settings → Privacy.
const privacySummary =
    "AR Farm Timer has no accounts, ads, or tracking. The app itself doesn't set cookies, but Cloudflare's bot "
    'protection sets a short-lived security cookie to keep out automated traffic. To understand how the site is '
    "used and improve it, it uses Cloudflare Web Analytics, a page statistics tool that doesn't use cookies. We see only "
    'combined statistics, not who you are, and we never sell data. Apart from that script, it doesn\'t load '
    'anything from other websites. Your timers, farms, and settings are stored only on this device, and backups are files '
    "you export yourself. If you turn on push alerts, our server stores your browser's push subscription and the "
    "alerts you've scheduled so it can send them through Apple, Google, or Mozilla. Each alert is deleted after "
    "it's sent. Unused subscriptions are deleted automatically, and turning alerts off deletes yours right away. "
    'See the full Privacy page for details.';

/// Shown next to "Enable alerts".
const privacyAlertNote = "Alert text (item and farm name) is stored on the push server until it's sent.";

sealed class PrivacyBlock {
  const PrivacyBlock(this.text);
  final String text;
}

class PrivacyHeading extends PrivacyBlock {
  const PrivacyHeading(super.text);
}

class PrivacyParagraph extends PrivacyBlock {
  const PrivacyParagraph(super.text, {this.email = false});

  /// When true the paragraph ends with [privacyEmail] as a mailto: link.
  final bool email;
}

class PrivacyBullet extends PrivacyBlock {
  const PrivacyBullet(super.text, {this.sub = const [], this.after});

  /// Nested bullet points, shown under [text].
  final List<String> sub;

  /// Text that continues the bullet after [sub].
  final String? after;
}

const privacyBlocks = <PrivacyBlock>[
  PrivacyParagraph(
    'AR Farm Timer (https://artimer.win) is a free, fan-made timer app for farming on ArcheRage. '
    'This notice explains what data the app handles and why.',
  ),
  PrivacyHeading("What we don't collect"),
  PrivacyBullet('No accounts. We never ask for your name, email, or any login.'),
  PrivacyBullet(
    'No tracking, and no analytics beyond Cloudflare\'s privacy-focused page statistics (see "Third parties").',
  ),
  PrivacyBullet('No ads.'),
  PrivacyBullet(
    "The app itself doesn't set cookies. Cloudflare's bot protection sets a short-lived security cookie "
    '(see "Cookies").',
  ),
  PrivacyHeading('Data stored on your device'),
  PrivacyParagraph(
    "Your timers, farms, and settings are saved only in your browser's local storage (or the app's storage) "
    "on your device. We don't receive this data. Backups are files you export and keep yourself. Clearing your "
    'browser or app data deletes this information from your device.',
  ),
  PrivacyParagraph(
    'When you select Agree on the "Before you use" notice, the app saves a small note in your browser\'s local '
    "storage so it doesn't show the notice again. This note stays on your device and isn't sent to our server. "
    'Clearing your browser data will bring the notice back.',
  ),
  PrivacyHeading('Optional push alerts'),
  PrivacyParagraph(
    'Push alerts are off by default. Nothing on this list is sent to our server unless you tap "Enable alerts." '
    'Once you turn them on, our push server (push.artimer.win, hosted on Cloudflare, with its database also '
    'kept by Cloudflare) stores:',
  ),
  PrivacyBullet(
    "Your browser's push subscription. This is an endpoint URL issued by your browser's push service (Apple, "
    'Google, or Mozilla), plus the encryption keys needed to send you notifications.',
  ),
  PrivacyBullet('A random subscription ID and the time the subscription was created.'),
  PrivacyBullet(
    'The time your subscription was last active, so unused subscriptions can be deleted automatically (see below).',
  ),
  PrivacyBullet(
    'For each alert you schedule, its fire time, title, short body text, and the link to open. The text usually '
    "names the item and says it's ready or about to wither, and it can include a farm name you chose.",
  ),
  PrivacyHeading('How long we keep it'),
  PrivacyBullet(
    "Each scheduled alert is deleted after it's sent. If an alert keeps failing to deliver, it's deleted after 5 attempts or 6 hours, whichever comes first.",
  ),
  PrivacyBullet(
    "We keep a delivery log for 7 days for troubleshooting, then delete it. The log holds the subscription ID, alert ID, scheduled and sent times, push status, delivery latency, and whether the send was started by the regular scheduler or a backup scheduled job. It doesn't contain any alert text.",
  ),
  PrivacyBullet(
    'Your push subscription stays until you turn alerts off, stops working, or goes unused. Turning alerts off '
    'deletes the subscription and every alert linked to it. Subscriptions that stop working, for example after '
    'you revoke notification permission or uninstall, are removed automatically. Unused subscriptions are also '
    'deleted automatically:',
    sub: [
      'if it never scheduled an alert, after 24 hours',
      'if it has no pending alerts, after 3 days without activity',
      'in every case, after 40 days without activity',
    ],
    after:
        'If your subscription is deleted this way, the app quietly sets it up again the next time you set a timer, '
        "so you don't need to do anything.",
  ),
  PrivacyHeading('Third parties'),
  PrivacyBullet(
    "Push delivery: notifications are delivered through your browser vendor's push service (Apple, Google, or "
    'Mozilla), which handles them under its own privacy policy.',
  ),
  PrivacyBullet(
    'Hosting: the app and its push server run on Cloudflare. Like any web host, Cloudflare processes connection '
    'data such as IP addresses in order to serve requests. Our push server is at push.artimer.win, behind '
    "Cloudflare's firewall, which counts requests from each IP address over a short time window to block floods "
    "of traffic. The push server also uses Cloudflare's rate limiting to cap how often each IP address (or, for "
    'IPv6, its network prefix) and each alert subscription can save, sync, or cancel timers, turn alerts off, or send a test alert. These counters are '
    "held by Cloudflare, last only about a minute, and aren't stored in our database. The app itself doesn't "
    'store IP addresses.',
  ),
  PrivacyBullet(
    'Page statistics: we use Cloudflare Web Analytics only to understand how the site is used and to improve it. '
    'It adds a small script from Cloudflare (static.cloudflareinsights.com) that reports page views, the page '
    'path, the referring page, your country, your browser and device type, and page load performance to '
    "Cloudflare. We see this as combined statistics in Cloudflare's dashboard, not as profiles of individual "
    "visitors, and we don't collect your name, email, or any account details. According to Cloudflare, it "
    "doesn't use cookies or local storage, doesn't fingerprint your device, doesn't track you across sites, and "
    "isn't used for advertising. To receive these reports and work out your country, Cloudflare processes your "
    'IP address, as any web host does. We never sell any data. If your browser or a content blocker blocks '
    "static.cloudflareinsights.com, you simply won't be counted in these statistics, and the app's timers, "
    "alerts, and everything else work exactly the same. You don't have to allow analytics to use the app.",
  ),
  PrivacyBullet(
    'No other sites: fonts and all other app files are served from this site. Apart from Cloudflare\'s page '
    "statistics script, the app doesn't load anything from other websites.",
  ),
  PrivacyBullet(
    "Server logs: Cloudflare keeps temporary runtime logs for our push server, kept according to Cloudflare's standard retention. These logs can record the hostname of the push service used (for example Apple, Google, or Mozilla) and the first 8 characters of your subscription ID. We haven't set up long-term storage or export of these logs.",
  ),
  PrivacyParagraph(
    "We don't sell your data. We share it only with the services that run the app for us, or if the law requires "
    'it. Cloudflare hosts the site and push server, handles rate limiting and bot protection, and provides page '
    'statistics. If you '
    'turn on push alerts, the push service your browser uses (Apple, Google, or Mozilla) delivers them. These '
    "services receive only what's described above, and our own code doesn't store IP addresses.",
  ),
  PrivacyHeading('Cookies'),
  PrivacyParagraph(
    "Our own code doesn't set any cookies, and page statistics don't use cookies. To protect the site from "
    "automated traffic, Cloudflare's bot protection sets a short-lived security cookie. According to "
    "Cloudflare, it helps tell people apart from bots, expires after 30 minutes of inactivity, isn't linked to "
    "any account or ID in the app, and isn't used to track you across sites. Its contents are encrypted so only "
    'Cloudflare can read them. If Cloudflare asks your browser to complete a quick security check, it may also '
    "set a second security cookie so you aren't asked again. These cookies are only used to keep the site "
    'secure, never for advertising. Cloudflare lists the cookies it uses in its documentation: '
    'https://developers.cloudflare.com/fundamentals/reference/policies-compliances/cloudflare-cookies/',
  ),
  PrivacyHeading('Your choices'),
  PrivacyBullet('You can use the app fully without push alerts, and then nothing about you is stored on our server.'),
  PrivacyBullet('You can turn alerts off at any time in the app to delete your subscription and pending alerts.'),
  PrivacyBullet('You can also revoke notification permission in your browser or device settings.'),
  PrivacyHeading('Contact'),
  PrivacyParagraph('Questions or requests about your data, or about this app: ', email: true),
  PrivacyHeading('Not affiliated'),
  PrivacyParagraph(
    'AR Farm Timer is an unofficial fan project. It is not made, endorsed, or affiliated with XLGAMES, '
    'Kakao Games, or ArcheRage. ArcheAge and related names belong to their respective owners.',
  ),
  PrivacyHeading('Changes'),
  PrivacyParagraph("If the way the app handles data changes, we'll update this page."),
];
