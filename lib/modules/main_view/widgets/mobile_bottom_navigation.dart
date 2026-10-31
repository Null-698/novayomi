import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:mangayomi/modules/widgets/native_ios_bar.dart';
import 'package:shiori/shiori.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/widgets/floating_nav_bar.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

class MainMobileBottomNavigation extends StatelessWidget {
  const MainMobileBottomNavigation({
    super.key,
    required this.isLongPressed,
    required this.location,
    required this.currentIndex,
    required this.dest,
    required this.route,
    required this.ref,
    required this.buildNavigationWidgetsMobile,
    required this.onDestinationSelected,
    required this.useFloatingNav,
    this.shrink = 0,
    this.onWake,
  });

  final bool isLongPressed;
  final String? location;
  final int currentIndex;
  final List<String> dest;
  final GoRouter route;
  final WidgetRef ref;
  final List<Widget> Function(WidgetRef, List<String>, BuildContext)
  buildNavigationWidgetsMobile;
  final Function(String) onDestinationSelected;
  final bool useFloatingNav;
  final double shrink;
  final VoidCallback? onWake;

  @override
  Widget build(BuildContext context) {
    final height = _getBottomNavigationHeight(isLongPressed, location);
    if (height == 0) {
      return const SizedBox.shrink();
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Aidoku's four primary destinations; keep the original GoRouter
      // destinations and feature screens rather than rebuilding the backend.
      final iosDest = <String>[
        '/NovelLibrary',
        '/browse',
        '/history',
        '/more',
      ].where((path) {
        if (path == '/NovelLibrary') {
          return dest.any((d) => d == path || d == '_library' ||
              d == '_enableLibSwitch');
        }
        if (path == '/history') {
          return dest.any((d) => d == path || d == '_activity');
        }
        return dest.contains(path);
      }).toList();
      final selected = iosDest.indexWhere((path) {
        if (path == '/NovelLibrary') {
          return location == path || location == '/MangaLibrary' ||
              location == '/AnimeLibrary';
        }
        if (path == '/history') {
          return location == path || location == '/updates';
        }
        return location == path;
      });
      const symbols = <String, String>{
        '/NovelLibrary': 'books.vertical',
        '/browse': 'globe',
        '/history': 'clock',
        '/more': 'gearshape',
      };
      const titles = <String, String>{
        '/NovelLibrary': 'Library',
        '/browse': 'Browse',
        '/history': 'History',
        '/more': 'Settings',
      };
      return SizedBox(
        width: context.width(1),
        height: 62 + MediaQuery.viewPaddingOf(context).bottom,
        child: NativeIosBar(
          kind: 'tabs',
          data: <String, Object?>{
            'selected': selected < 0 ? 0 : selected,
            'items': [
              for (final path in iosDest)
                <String, String>{
                  'title': titles[path]!,
                  'symbol': symbols[path]!,
                },
            ],
          },
          onSelected: (index) {
            if (index >= 0 && index < iosDest.length) {
              onDestinationSelected(iosDest[index]);
            }
          },
          onAction: (action) {
            if (action == 'search') {
              route.push('/globalSearch', extra: (null, ItemType.novel));
            }
          },
        ),
      );
    }

    if (useFloatingNav) {
      return SizedBox(
        width: context.width(1),
        height: height,
        child: FloatingNavBar(
          destinations: buildNavigationWidgetsMobile(
            ref,
            dest,
            context,
          ).cast<NavigationDestination>(),
          currentIndex: currentIndex,
          onSelected: (newIndex) => onDestinationSelected(dest[newIndex]),
          showLabels: context.isLandscape,
          shrink: shrink,
          onWake: onWake,
        ),
      );
    }

    return SizedBox(
      width: context.width(1),
      height: height,
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          labelTextStyle: const WidgetStatePropertyAll(
            TextStyle(overflow: TextOverflow.ellipsis),
          ),
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ShioriShape.sheet),
          ),
        ),
        child: NavigationBar(
          animationDuration: ShioriMotion.exitSlow,
          selectedIndex: currentIndex,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: buildNavigationWidgetsMobile(ref, dest, context),
          onDestinationSelected: (newIndex) {
            onDestinationSelected(dest[newIndex]);
          },
        ),
      ),
    );
  }

  static double? _getBottomNavigationHeight(
    bool isLongPressed,
    String? location,
  ) {
    if (isLongPressed) return 0;

    const validLocations = {
      '/MangaLibrary',
      '/AnimeLibrary',
      '/NovelLibrary',
      '/history',
      '/updates',
      '/browse',
      '/more',
      '/trackerLibrary',
    };

    return (location == null || validLocations.contains(location)) ? null : 0;
  }
}
