import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/pwa_bridge.dart';
import '../theme/app_theme.dart';

/// Step-by-step "Add to Home Screen" guide for the web app (PWA), with one
/// tab for iPhone/iPad and one for Android. Opens the matching tab when the
/// platform is known from the browser's user agent.
class InstallGuideScreen extends StatelessWidget {
  const InstallGuideScreen({super.key, required this.info});
  final PwaInfo info;

  /// The hosted web app (Cloudflare Pages).
  static const liveUrl = 'https://artimer.win/';

  static Future<void> open(BuildContext context, PwaInfo info) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InstallGuideScreen(info: info)));

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: info.android && !info.ios ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('HOW TO INSTALL'),
          bottom: const TabBar(
            labelColor: AppColors.gold,
            indicatorColor: AppColors.gold,
            unselectedLabelColor: AppColors.parchment,
            tabs: [
              Tab(icon: Icon(Icons.phone_iphone), text: 'iPhone / iPad'),
              Tab(icon: Icon(Icons.phone_android), text: 'Android'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _GuidePage(
              key: const Key('guideIos'),
              info: info,
              steps: const [
                'Open the link below in Safari. Other iOS browsers (16.4+) may also offer "Add to Home Screen" '
                    'under Share, but Safari always works.',
                'Tap the Share button (the square with an arrow pointing up).',
                'Scroll down and tap "Add to Home Screen".',
                'Tap "Add" in the top-right corner.',
                'Open the app from its new Home Screen icon.',
              ],
              notes: const [
                'The Home Screen app keeps its own storage, separate from the Safari tab. To move timers, '
                    'use Settings → Backup → Export in the tab, then Import in the installed app.',
                'Push alerts only work in the Home Screen app on iOS 16.4 or newer. Turn them on in '
                    'Settings → Alerts → Enable alerts.',
              ],
            ),
            _GuidePage(
              key: const Key('guideAndroid'),
              info: info,
              steps: const [
                'Open the link below in Chrome.',
                'Tap the ⋮ menu (top right).',
                'Tap "Install app" (or "Add to Home screen").',
                'Confirm with "Install" (or "Add").',
                'Open the app from your home screen or app drawer.',
              ],
              notes: const [
                'Chrome may also show an install prompt on its own. Accepting it does the same thing.',
                'The installed app keeps its own storage, separate from the browser tab. Use '
                    'Settings → Backup to move timers.',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GuidePage extends StatelessWidget {
  const _GuidePage({super.key, required this.info, required this.steps, required this.notes});
  final PwaInfo info;
  final List<String> steps;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: [
        if (info.standalone)
          Card(
            color: const Color(0xFF1E2A1E),
            child: const ListTile(
              leading: Icon(Icons.check_circle, color: AppColors.ready),
              title: Text("You're already using the installed app."),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 13,
                          backgroundColor: const Color(0x55C9A45C),
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(steps[i])),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.link, color: AppColors.gold),
            title: const Text(InstallGuideScreen.liveUrl, style: TextStyle(fontSize: 14)),
            subtitle: Text('This is a web app. There is no app-store download.', style: small),
            trailing: IconButton(
              tooltip: 'Copy link',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: InstallGuideScreen.liveUrl));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                }
              },
            ),
          ),
        ),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 16, color: AppColors.goldDim),
                const SizedBox(width: 8),
                Expanded(child: Text(n, style: small)),
              ],
            ),
          ),
      ],
    );
  }
}
