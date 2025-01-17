import 'dart:collection';
import 'dart:convert';
import 'package:download_assets/download_assets.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:four_training/data/globals.dart';
import 'package:file/file.dart';
import 'package:path/path.dart';

final fileSystemProvider = Provider<FileSystem>((ref) {
  return const LocalFileSystem();
});

/// Unique identifier of an image or a page
typedef Resource = ({String name, String langCode});

/// Provide image data (base64-encoded)
/// Returns empty string in case something went wrong
/// TODO improve error handling
final imageContentProvider = Provider.family<String, Resource>((ref, res) {
  final String path = ref.watch(languageProvider(res.langCode)).path;
  if (path == '') {
    debugPrint(
        "Error: Can't load image ${res.name} in language ${res.langCode}");
    return '';
  }
  final fileSystem = ref.watch(fileSystemProvider);
  File image = fileSystem.file(join(path, 'files', res.name));
  debugPrint("Successfully loaded ${res.name}");
  return base64Encode(image.readAsBytesSync());
});

/// Provide HTML content of a specific page in a specific language
/// Returns empty string in case something went wrong
/// TODO: improve error handling
final pageContentProvider =
    FutureProvider.family<String, Resource>((ref, page) async {
  final fileSystem = ref.watch(fileSystemProvider);
  final lang = ref.watch(languageProvider(page.langCode));
  Page? pageDetails = lang.pages[page.name];
  if (pageDetails == null) {
    debugPrint(
        "Internal error: Couldn't find page ${page.name}/${page.langCode}");
    return '';
  }
  if (lang.path == '') {
    debugPrint('Error: Language ${lang.languageCode} not available.');
    return '';
  }

  debugPrint("Fetching content of '${page.name}/${page.langCode}'...");
  String content = await fileSystem
      .file(join(lang.path, pageDetails.fileName))
      .readAsString();

  // Load images directly into the HTML:
  // Replace <img src="xyz.png"> with <img src="base64-encoded image data">
  content =
      content.replaceAllMapped(RegExp(r'src="files/([^.]+.png)"'), (match) {
    if (!lang.images.containsKey(match.group(1))) {
      debugPrint(
          'Warning: image ${match.group(1)} missing (in ${pageDetails.fileName})');
      return match.group(0)!;
    }
    String imageData = ref.watch(
        imageContentProvider((name: match.group(1)!, langCode: page.langCode)));
    return 'src="data:image/png;base64,$imageData"';
  });
  return content;
});

/// Usage:
/// ref.watch(languageProvider('de')) -> get German Language object
/// ref.watch(languageProvider('en').notifier) -> get English LanguageController
final languageProvider =
    NotifierProvider.family<LanguageController, Language, String>(() {
  return LanguageController();
});

class LanguageController extends FamilyNotifier<Language, String> {
  @protected
  String languageCode = '';
  final DownloadAssetsController _controller;

  /// We use dependency injection (optional parameters [assetsController])
  /// so that we can test the class well
  LanguageController({DownloadAssetsController? assetsController})
      : _controller = assetsController ?? DownloadAssetsController();

  @override
  Language build(String arg) {
    languageCode = arg;
    return Language(
        '', const {}, const [], const {}, '', 0, DateTime(2023, 1, 1));
  }

  Future<void> init() async {
    final fileSystem = ref.watch(fileSystemProvider);
    await _controller.init(assetDir: "assets-$languageCode");

    try {
      // Now we store the full path to the language
      String path = _controller.assetsDir! +
          Globals.pathStart +
          languageCode +
          Globals.pathEnd;
      debugPrint("Path: $path");
      Directory dir = fileSystem.directory(path);

      bool downloaded = await _controller.assetsDirAlreadyExists();
      debugPrint("assets ($languageCode) loaded: $downloaded");
      if (!downloaded) await _download();
      downloaded = true;

      // Store the size of the downloaded directory
      int sizeInKB = await _calculateMemoryUsage(dir);

      // Get the timestamp: When were our contents stored on the device?
      FileStat stat =
          await FileStat.stat(join(path, 'structure', 'contents.json'));
      DateTime timestamp = stat.changed; // TODO is this UTC or local time?

      // Read structure/contents.json as our source of truth:
      // Which pages are available, what is the order in the menu
      var structure = jsonDecode(fileSystem
          .file(join(path, 'structure', 'contents.json'))
          .readAsStringSync());

      final Map<String, Page> pages = {};
      final List<String> pageIndex = [];
      final Map<String, Image> images = {};

      for (var element in structure["worksheets"]) {
        // TODO add error handling
        pageIndex.add(element['page']);
        pages[element['page']] = Page(element['page'], element['title'],
            element['filename'], element['version']);
      }
      await _checkConsistency(dir, pages);

      // Register available images
      await for (var file in fileSystem
          .directory(join(path, 'files'))
          .list(recursive: false, followLinks: false)) {
        if (file is File) {
          images[basename(file.path)] = Image(basename(file.path));
        } else {
          debugPrint("Found unexpected element $file in files/ directory");
        }
      }
      state = Language(
          languageCode, pages, pageIndex, images, path, sizeInKB, timestamp);
    } catch (e) {
      String msg = "Error initializing data structure: $e";
      debugPrint(msg);
      // Delete the whole folder
      _controller.clearAssets();
      throw Exception(msg);
    }
  }

  // TODO: are there race conditions possible in our LanguageController?
  Future<void> deleteResources() async {
    await _controller.clearAssets();
    state =
        Language('', const {}, const [], const {}, '', 0, DateTime(2023, 1, 1));
  }

  /// Download all files for one language via DownloadAssetsController
  Future _download() async {
    debugPrint("Starting downloadLanguage: $languageCode ...");
    // URL of the zip file to be downloaded
    String remoteUrl = Globals.urlStart + languageCode + Globals.urlEnd;

    await _controller.startDownload(
      assetsUrls: [remoteUrl],
      onProgress: (progressValue) {
        if (progressValue < 20) {
          // The value goes for some reason only up to 18.7 or so ...
          String progress = "Downloading $languageCode: ";

          for (int i = 0; i < 20; i++) {
            progress += (i <= progressValue) ? "|" : ".";
          }
          debugPrint("$progress ${progressValue.round()}");
        } else {
          debugPrint("Download completed");
        }
      },
    );
  }

  /// Return the total size of all files in our directory in kB
  Future<int> _calculateMemoryUsage(Directory dir) async {
    var files = await dir.list(recursive: true).toList();
    var sizeInBytes =
        files.fold(0, (int sum, file) => sum + file.statSync().size);
    return (sizeInBytes / 1000).ceil(); // let's never round down
  }

  /// Check whether all files mentioned in structure/contents.json are present
  /// and whether there is no extra file present
  ///
  /// TODO maybe remove this function on startup. Rather implement gracious
  /// error handling if a page we expect to be there can't be loaded because
  /// a HTML file is missing...
  Future<void> _checkConsistency(
      Directory dir, final Map<String, Page> pages) async {
    Set<String> files = {};
    await for (var file in dir.list(recursive: false, followLinks: false)) {
      if (file is File) {
        files.add(basename(file.path));
      }
    }
    pages.forEach((key, page) {
      if (!files.remove(page.fileName)) {
        debugPrint(
            "Warning: Structure mentions ${page.fileName} but the file is missing");
      }
    });
    if (files.isNotEmpty) debugPrint("Warning: Found orphaned files $files");
  }
}

/// Holds properties of a page.
/// HTML content is loaded on demand via the pageContentProvider
@immutable
class Page {
  /// English identifier
  final String name;

  /// (translated) Title
  final String title;

  /// (translated) Name of the HTML file
  final String fileName;

  final String version;

  const Page(this.name, this.title, this.fileName, this.version);
}

/// Holds properties of an image.
/// Content is loaded on demand via the imageContentProvider
@immutable
class Image {
  final String name;

  const Image(this.name);
}

@immutable
class Language {
  final String languageCode;

  /// Check this getter to see if we have any meaningful data
  bool get downloaded => languageCode != '';

  /// Holds our pages identified by their English name (e.g. "Hearing_from_God")
  final Map<String, Page> pages;

  /// Define the order of pages in the menu: List of page names
  /// Not all pages must be in the menu, so every item in this list must be
  /// in _pages, but not every item of _pages must be in this list
  final List<String> pageIndex;

  final Map<String, Image> images;

  /// local path to the directory holding all content
  final String path;

  /// The size of the downloaded directory (kB = kilobytes)
  final int sizeInKB;

  /// When were the files downloaded on our device? (file system attribute)
  final DateTime downloadTimestamp;

  const Language(this.languageCode, this.pages, this.pageIndex, this.images,
      this.path, this.sizeInKB, this.downloadTimestamp);

  /// Returns an list with all the worksheet titles in the menu.
  /// The list is ordered as identifier -> translated title
  LinkedHashMap<String, String> getPageTitles() {
    LinkedHashMap<String, String> titles = LinkedHashMap<String, String>();
    for (int i = 0; i < pageIndex.length; i++) {
      titles[pageIndex[i]] = pages[pageIndex[i]]!.title;
    }
    return titles;
  }
}
