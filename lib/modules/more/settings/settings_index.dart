import 'package:mangayomi/l10n/generated/app_localizations.dart';

/// One setting, or settings screen, that the search in Settings can find.
class SettingsEntry {
  const SettingsEntry({
    required this.title,
    required this.subtitle,
    required this.section,
    required this.route,
    this.extra,
  });

  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations)? subtitle;

  /// The screen the setting lives on, shown as its path.
  final String Function(AppLocalizations) section;
  final String route;

  /// What the route needs to open the right place, such as a section.
  final Object? extra;
}

/// Every setting the search can find, by the screen that holds it.
///
/// Built from the titles of the settings screens' rows; a new row is found
/// once it is listed here. test/modules/more/settings_index_test.dart checks
/// that every route still exists.
final settingsIndex = <SettingsEntry>[
  SettingsEntry(
    title: (l) => l.general,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.auto_library_update,
    subtitle: (l) => l.auto_library_update_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.library_update_restrictions,
    subtitle: (l) => l.library_update_restrictions_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.auto_library_update_wifi_only,
    subtitle: (l) => l.auto_library_update_wifi_only_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.dns_over_https,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.dns_provider,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.custom,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.custom_dns_title,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.default_user_agent,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.onboarding_replay,
    subtitle: (l) => l.onboarding_replay_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.cloudflare_bypass_proxy,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.memory_overlay,
    subtitle: (l) => l.memory_overlay_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.show_nav_double_tap_tooltip,
    subtitle: (l) => l.show_nav_double_tap_tooltip_subtitle,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.enable_discord_rpc,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.hide_discord_rpc_incognito,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.rpc_show_reading_watching_progress,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.rpc_show_title,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.rpc_show_cover_image,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.custom_doh_url,
    subtitle: null,
    section: (l) => l.general,
    route: '/general',
  ),
  SettingsEntry(
    title: (l) => l.appearance,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.pure_black_dark_mode,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.tint_surfaces_with_palette,
    subtitle: (l) => l.tint_surfaces_with_palette_subtitle,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.tv_home_beta,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.app_ui_scale,
    subtitle: (l) => l.app_ui_scale_subtitle,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.floating_navigation_bar,
    subtitle: (l) => l.floating_navigation_bar_description,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.reorder_navigation,
    subtitle: (l) => l.reorder_navigation_description,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.app_language,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.relative_timestamp,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.date_format,
    subtitle: null,
    section: (l) => l.appearance,
    route: '/appearance',
  ),
  SettingsEntry(
    title: (l) => l.reorder_navigation,
    subtitle: null,
    section: (l) => l.reorder_navigation,
    route: '/customNavigationSettings',
  ),
  SettingsEntry(
    title: (l) => l.anime_only_tv_layout,
    subtitle: null,
    section: (l) => l.reorder_navigation,
    route: '/customNavigationSettings',
  ),
  SettingsEntry(
    title: (l) => l.group_nav_destinations,
    subtitle: (l) => l.group_nav_destinations_subtitle,
    section: (l) => l.reorder_navigation,
    route: '/customNavigationSettings',
  ),
  SettingsEntry(
    title: (l) => l.merge_library_nav_mobile,
    subtitle: null,
    section: (l) => l.reorder_navigation,
    route: '/customNavigationSettings',
  ),
  SettingsEntry(
    title: (l) => l.novel_reader,
    subtitle: (l) => l.settings_novel_reader_summary,
    section: (l) => l.novel_reader,
    route: '/novelReaderMode',
  ),
  SettingsEntry(
    title: (l) => l.keyboard_shortcuts,
    subtitle: (l) => l.settings_keyboard_shortcuts_summary,
    section: (l) => l.keyboard_shortcuts,
    route: '/keyboardShortcuts',
  ),
  SettingsEntry(
    title: (l) => l.downloads,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.only_on_wifi,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.save_as_cbz_archive,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.delete_download_after_reading,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.download_new_chapters,
    subtitle: (l) => l.download_new_chapters_subtitle,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.download_ahead,
    subtitle: (l) => l.download_ahead_subtitle,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.allow_concurrent_downloads,
    subtitle: (l) => l.allow_concurrent_downloads_subtitle,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.concurrent_downloads,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.download_delay,
    subtitle: (l) => l.download_delay_subtitle,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.download_location,
    subtitle: (l) => l.download_location_info,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.add_local_folder,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.rescan_local_folder,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.name,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.local_folder_structure,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.delete,
    subtitle: null,
    section: (l) => l.downloads,
    route: '/downloads',
  ),
  SettingsEntry(
    title: (l) => l.tracking,
    subtitle: null,
    section: (l) => l.tracking,
    route: '/track',
  ),
  SettingsEntry(
    title: (l) => l.updateProgressAfterReading,
    subtitle: null,
    section: (l) => l.tracking,
    route: '/track',
  ),
  SettingsEntry(
    title: (l) => l.syncing,
    subtitle: null,
    section: (l) => l.syncing,
    route: '/sync',
  ),
  SettingsEntry(
    title: (l) => l.sync_on,
    subtitle: null,
    section: (l) => l.syncing,
    route: '/sync',
  ),
  SettingsEntry(
    title: (l) => l.sync_auto,
    subtitle: null,
    section: (l) => l.syncing,
    route: '/sync',
  ),
  SettingsEntry(
    title: (l) => l.browse,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.anime_only_beta,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.manga_extensions_repo,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.manage_manga_repo_urls,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.anime_extensions_repo,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.manage_anime_repo_urls,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.novel_extensions_repo,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.manage_novel_repo_urls,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.check_for_extension_updates,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.create_backup,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.restore_backup,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.roll_back_last_change,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.backup_frequency,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.backup_location,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.encrypt_backups,
    subtitle: (l) => l.encrypt_backups_info,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.compression_level,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.missing_source_check_title,
    subtitle: (l) => l.missing_source_check_subtitle,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.merge_manga_title,
    subtitle: (l) => l.merge_manga_subtitle,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.delete_source_title,
    subtitle: (l) => l.delete_source_subtitle,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.clear_chapter_and_episode_cache,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.clear_chapter_or_episode_cache_on_app_launch,
    subtitle: null,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.clean_database,
    subtitle: (l) => l.clean_database_desc,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.clear_library,
    subtitle: (l) => l.clear_library_desc,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.clear_local_library,
    subtitle: (l) => l.clear_local_library_desc,
    section: (l) => l.data_and_storage,
    route: '/dataAndStorage',
  ),
  SettingsEntry(
    title: (l) => l.auto_extensions_updates,
    subtitle: (l) => l.auto_extensions_updates_subtitle,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.developer_mode,
    subtitle: (l) => l.developer_mode_subtitle,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.only_include_pinned_sources,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.nsfw_sources_show,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.clear_all_sources,
    subtitle: null,
    section: (l) => l.browse,
    route: '/browseS',
  ),
  SettingsEntry(
    title: (l) => l.security,
    subtitle: null,
    section: (l) => l.security,
    route: '/security',
  ),
  SettingsEntry(
    title: (l) => l.app_lock,
    subtitle: (l) => l.app_lock_description,
    section: (l) => l.security,
    route: '/security',
  ),
  SettingsEntry(
    title: (l) => l.app_lock_delay,
    subtitle: null,
    section: (l) => l.security,
    route: '/security',
  ),
  SettingsEntry(
    title: (l) => l.secure_screen,
    subtitle: (l) => l.secure_screen_subtitle,
    section: (l) => l.security,
    route: '/security',
  ),
  SettingsEntry(
    title: (l) => l.hide_notification_content,
    subtitle: (l) => l.hide_notification_content_subtitle,
    section: (l) => l.security,
    route: '/security',
  ),
];
