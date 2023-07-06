import 'dart:convert';
import 'package:download_assets/download_assets.dart';
import 'package:file/local.dart';
import 'package:flutter/cupertino.dart';
import 'package:four_training/data/globals.dart';
import 'package:file/file.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:http/http.dart' as http;

/// A page with HTML code: content is loaded on demand
class Page {
  /// English identifier
  final String name;

  /// (translated) Name of the HTML file
  final String fileName;

  /// HTML code of this page or null if not yet loaded
  String? content;

  Page(this.name, this.fileName);
}

/// Images to be used in pages: content is loaded on demand
class Image {
  final String name;

  /// Base64 encoded image content or null if not yet loaded
  String? data;

  Image(this.name);
}

/// late members will be initialized after calling init()
class Language {
  final String languageCode;

  /// URL of the zip file to be downloaded
  final String remoteUrl;

  /// full local path to directory holding all content
  late final String path;

  /// Directory object of path
  late final Directory _dir;

  bool downloaded = false;

  /// Holds our pages identified by their English name (e.g. "Hearing_from_God")
  final Map<String, Page> _pages = {};

  /// Define the order of pages in the menu: List of page names
  /// Not all pages must be in the menu, so every item in this list must be
  /// in _pages, but not every item of _pages must be in this list
  final List<String> _pageIndex = [];

  final Map<String, Image> _images = {};
  DateTime? _timestamp; // TODO
  int _commitsSinceDownload = 0; // TODO

  final DownloadAssetsController _controller;
  final FileSystem _fs;

  /// We use dependency injection (optional parameters [assetsController] and
  /// [fileSystem]) so that we can test the class well
  Language(this.languageCode,
      {DownloadAssetsController? assetsController, FileSystem? fileSystem})
      : remoteUrl = urlStart + languageCode + urlEnd,
        _controller = assetsController ?? DownloadAssetsController(),
        _fs = fileSystem ?? const LocalFileSystem();

  Future init() async {
    await _controller.init(assetDir: "assets-$languageCode");

    try {
      // Now we store the full path to the language
      path = _controller.assetsDir! + pathStart + languageCode + pathEnd;
      debugPrint("Path: $path");
      _dir = _fs.directory(path);

      downloaded = await _controller.assetsDirAlreadyExists();
      // TODO check that in every unexpected behavior the folder gets deleted and downloaded is false
      debugPrint("assets ($languageCode) loaded: $downloaded");
      if (!downloaded) await _download();

      _timestamp = await _getTimestamp();
      _commitsSinceDownload = await _fetchLatestCommits();

      // Read structure/contents.json as our source of truth:
      // Which pages are available, what is the order in the menu
      var structure = jsonDecode(_fs
          .file(join(path, 'structure', 'contents.json'))
          .readAsStringSync());

      for (Map element in structure) {
        element.forEach((key, value) {
          _pageIndex.add(key);
          _pages[key] = Page(key, value);
        });
      }

      _checkConsistency();

      // Register available images
      await for (var file in _fs
          .directory(join(path, 'files'))
          .list(recursive: false, followLinks: false)) {
        if (file is File) {
          _images[basename(file.path)] = Image(basename(file.path));
        } else {
          debugPrint("Found unexpected element $file in files/ directory");
        }
      }
    } catch (e) {
      String msg = "Error initializing data structure: $e";
      debugPrint(msg);
      // Delete the whole folder (TODO make sure this is called in every unexpected situation)
      downloaded = false;
      _controller.clearAssets();
      throw Exception(msg);
    }
  }

  /// Check whether all files mentioned in structure/contents.json are present
  /// and whether there is no extra file present
  ///
  /// TODO maybe remove this function on startup. Rather implement gracious
  /// error handling if a page we expect to be there can't be loaded because
  /// a HTML file is missing...
  Future<void> _checkConsistency() async {
    Set<String> files = {};
    await for (var file in _dir.list(recursive: false, followLinks: false)) {
      if (file is File) {
        files.add(basename(file.path));
      }
    }
    _pages.forEach((key, page) {
      if (!files.remove(page.fileName)) {
        debugPrint(
            "Warning: Structure mentions ${page.fileName} but the file is missing");
      }
    });
    if (files.isNotEmpty) debugPrint("Warning: Found orphaned files $files");
  }

  Future _download() async {
    debugPrint("Starting downloadLanguage: $languageCode ...");

    try {
      await _controller.startDownload(
        assetsUrls: [remoteUrl],
        onProgress: (progressValue) {
          if (progressValue < 20) {
            // The value goes for some reason only up to 18.7 or so ...
            String progress = "Downloading $languageCode: ";

            for (int i = 0; i < 20; i++) {
              progress += (i <= progressValue) ? "|" : ".";
            }
            //debugPrint("$progress ${progressValue.round()}");
          } else {
            debugPrint("Download completed");
            downloaded = true;
          }
        },
      );
    } on DownloadAssetsException catch (e) {
      debugPrint(e.toString());
      downloaded = false;
    }
  }

  Future<void> removeAssets() async {
    await _controller.clearAssets();
  }

  Future<DateTime> _getTimestamp() async {
    DateTime timestamp = DateTime.now();

    try {
      await for (var file in _dir.list(recursive: false, followLinks: false)) {
        if (file is File) {
          FileStat stat = await FileStat.stat(file.path);
          timestamp = stat.changed;
          break;
        }
      }
    } catch (e) {
      String msg = "Error getting timestamp: $e";
      debugPrint(msg);
      return Future.error(msg);
    }
    debugPrint(timestamp.toString());
    return timestamp;
  }

  /// Returns the timestamp in a human readable string. If we don't have a timestamp, an empty string is returned.
  String formatTimestamp() {
    if (_timestamp == null) return "";
    return DateFormat('yyyy-MM-dd HH:mm').format(_timestamp!);
  }

  Future<int> _fetchLatestCommits() async {
    if (_timestamp == null) {
      return Future.error("TODO");
    }
    var t = _timestamp!.subtract(const Duration(
        days: 500)); // TODO just for testing, use timestamp instead
    var uri = latestCommitsStart +
        languageCode +
        latestCommitsEnd +
        t.toIso8601String();
    debugPrint(uri);
    final response = await http.get(Uri.parse(uri));

    if (response.statusCode == 200) {
      // = OK response
      var data = json.decode(response.body);
      int commits = data.length;
      debugPrint(
          "Found $commits new commits since download on $t ($languageCode)");
      if (commits > 0) newCommitsAvailable = true;
      return commits;
    } else {
      return Future.error(
          "Failed to fetch latest commits ${response.statusCode}");
    }
  }

  /// Return the HTML code of the page identified by [index]
  /// If we don't have it already cached in memory, we read it from the file in our local storage.
  /// TODO error handling / select by name instead of index?
  Future<String> getPageContent(int index) async {
    assert(index >= 0);
    assert(index < _pages.length);
    Page? page = _pages[_pageIndex[index]];
    if (page == null) {
      debugPrint("Internal error: Couldn't find page with index $index");
      return "";
    }
    if (page.content == null) {
      debugPrint(
          "Fetching content of '${page.name}' (lang: $languageCode, index: $index)...");
      page.content = await _fs.file(join(path, page.fileName)).readAsString();

      // Load images if necessary
      for (var image in _images.values) {
        if (page.content!.contains(image.name)) {
          if (image.data == null) {
            // Load image data. TODO move this into the Image class?
            image.data =
                imageToBase64(_fs.file(join(path, 'files', image.name)));
            debugPrint("Successfully loaded ${image.name}");
          }
          page.content = page.content!.replaceAll(
              "files/${image.name}", "data:image/png;base64,${image.data}");
        }
      }
    }
    return page.content!;
  }

  /// Returns a list with all the worksheet titles available.
  /// They are the names of the HTML files, e.g. "Hearing_from_God.html"
  List<String> getPageTitles() {
    List<String> titles = [];
    for (var page in _pages.values) {
      titles.add(page.fileName);
    }
    return titles;
  }

  /// Get the worksheet index for a given title (HTML file name)
  /// Returns null if it couldn't be found. Index starts with 0.
  int? getIndexByTitle(String title) {
    for (Page page in _pages.values) {
      if (page.fileName == title) {
        int index = _pageIndex.indexOf(page.name);
        if (index >= 0) return index;
      }
    }

    debugPrint("Warning: Couldn't find index for page $title");
    return null;
  }
}

String imageToBase64(File image) {
  List<int> imageBytes = image.readAsBytesSync();
  return base64Encode(imageBytes);
}
