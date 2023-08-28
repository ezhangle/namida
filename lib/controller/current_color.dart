import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:get/get.dart';

import 'package:namida/class/color_m.dart';
import 'package:namida/class/track.dart';
import 'package:namida/controller/indexer_controller.dart';
import 'package:namida/controller/player_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:palette_generator/palette_generator.dart';

Color get playerStaticColor => Color(SettingsController.inst.staticColor.value);

class CurrentColor {
  static CurrentColor get inst => _instance;
  static final CurrentColor _instance = CurrentColor._internal();
  CurrentColor._internal();

  Color get color => _namidaColor.value.color;
  List<Color> get palette => _namidaColor.value.palette;
  Color get currentColorScheme => _colorSchemeOfSubPages.value ?? color;
  int get colorAlpha => Get.isDarkMode ? 200 : 120;

  final Rx<NamidaColor> _namidaColor = NamidaColor(
    used: playerStaticColor,
    mix: playerStaticColor,
    palette: [playerStaticColor],
  ).obs;

  final _colorSchemeOfSubPages = Rxn<Color>();

  final paletteFirstHalf = <Color>[].obs;
  final paletteSecondHalf = <Color>[].obs;

  /// Same fields exists in [Player] class, they can be used but these ones ensure updating the color only after extracting.
  final currentPlayingTrack = Rxn<Selectable>();
  final currentPlayingIndex = 0.obs;

  final isGeneratingAllColorPalettes = false.obs;

  final colorsMap = <String, NamidaColor>{};

  Timer? _colorsSwitchTimer;
  void switchColorPalettes(bool isPlaying) {
    _colorsSwitchTimer?.cancel();
    _colorsSwitchTimer = null;
    final durms = isPlaying ? 500 : 2000;
    _colorsSwitchTimer = Timer.periodic(Duration(milliseconds: durms), (timer) {
      if (SettingsController.inst.enablePartyModeColorSwap.value) {
        if (paletteFirstHalf.isEmpty) return;

        final lastItem1 = paletteFirstHalf.last;
        paletteFirstHalf.remove(lastItem1);
        paletteFirstHalf.insertSafe(0, lastItem1);

        if (paletteSecondHalf.isEmpty) return;
        final lastItem2 = paletteSecondHalf.last;
        paletteSecondHalf.remove(lastItem2);
        paletteSecondHalf.insertSafe(0, lastItem2);
      }
    });
  }

  void updateColorAfterThemeModeChange() {
    final nc = _namidaColor.value;
    _namidaColor.value = NamidaColor(
      used: nc.color.withAlpha(colorAlpha),
      mix: nc.mix,
      palette: nc.palette,
    );
  }

  void updatePlayerColorFromColor(Color color, [bool customAlpha = true]) async {
    final colorWithAlpha = customAlpha ? color.withAlpha(colorAlpha) : color;
    _namidaColor.value = NamidaColor(
      used: colorWithAlpha,
      mix: colorWithAlpha,
      palette: [colorWithAlpha],
    );
  }

  Future<void> updatePlayerColorFromTrack(Selectable? track, int? index, {bool updateIndexOnly = false}) async {
    if (!updateIndexOnly && track != null && SettingsController.inst.autoColor.value) {
      final color = await getTrackColors(track.track);
      _namidaColor.value = color;
      _updateCurrentPaletteHalfs(color);
    }
    if (track != null) {
      currentPlayingTrack.value = null; // nullifying to re-assign safely if subtype has changed
      currentPlayingTrack.value = track;
    }
    if (index != null) {
      currentPlayingIndex.value = index;
    }
  }

  Future<NamidaColor> getTrackColors(
    Track track, {
    bool fallbackToPlayerStaticColor = true,
    bool delightnedAndAlpha = true,
    bool useIsolate = _defaultUseIsolate,
  }) async {
    NamidaColor maybeDelightned(NamidaColor? nc) {
      if (nc == null) {
        final c = fallbackToPlayerStaticColor ? playerStaticColor : currentColorScheme;
        return NamidaColor(
          used: c.lighter,
          mix: c.lighter,
          palette: [c.lighter],
        );
      } else {
        return NamidaColor(
          used: delightnedAndAlpha ? nc.used?.withAlpha(colorAlpha).delightned : nc.used,
          mix: delightnedAndAlpha ? nc.mix.withAlpha(colorAlpha).delightned : nc.mix,
          palette: nc.palette,
        );
      }
    }

    final valInMap = colorsMap[track.path.getFilename];
    if (valInMap != null) return maybeDelightned(valInMap);

    NamidaColor? nc = await _extractPaletteFromImage(
      track.pathToImage,
      useIsolate: useIsolate,
    );

    final finalnc = maybeDelightned(nc);
    _updateInColorMap(track.filename, finalnc);
    return finalnc;
  }

  /// Equivalent to calling [getTrackColors] with [delightnedAndAlpha == true]
  Future<Color> getTrackDelightnedColor(Track track, {bool fallbackToPlayerStaticColor = false}) async {
    final nc = await getTrackColors(track, fallbackToPlayerStaticColor: fallbackToPlayerStaticColor, delightnedAndAlpha: true);
    return nc.color;
  }

  void updateCurrentColorSchemeOfSubPages([Color? color, bool customAlpha = true]) async {
    final colorWithAlpha = customAlpha ? color?.withAlpha(colorAlpha) : color;
    _colorSchemeOfSubPages.value = colorWithAlpha;
  }

  Color mixIntColors(Iterable<Color> colors) {
    int red = 0;
    int green = 0;
    int blue = 0;

    for (final color in colors) {
      red += (color.value >> 16) & 0xFF;
      green += (color.value >> 8) & 0xFF;
      blue += color.value & 0xFF;
    }

    red ~/= colors.length;
    green ~/= colors.length;
    blue ~/= colors.length;

    return Color.fromARGB(255, red, green, blue);
  }

  Future<NamidaColor?> _extractPaletteFromImage(
    String imagePath, {
    bool forceReExtract = false,
    bool useIsolate = _defaultUseIsolate,
  }) async {
    if (!forceReExtract && !await File(imagePath).exists()) {
      return null;
    }

    final paletteFile = File("${AppDirs.PALETTES}${imagePath.getFilenameWOExt}.palette");

    // -- try reading the cached file
    if (!forceReExtract) {
      final response = await paletteFile.readAsJson();
      if (response != null) {
        final nc = NamidaColor.fromJson(response);
        printy("Color Read From File");
        return nc;
      } else {
        await paletteFile.deleteIfExists();
      }
    }

    // -- file doesnt exist or couldn't be read or [forceReExtract==true]
    try {
      final pcolors = await _extractPaletteGenerator(imagePath, useIsolate: useIsolate);
      if (pcolors.isNotEmpty) {
        final nc = NamidaColor(used: null, mix: mixIntColors(pcolors), palette: pcolors.toList());
        await paletteFile.writeAsJson(nc.toJson());
        Indexer.inst.updateColorPalettesSizeInStorage(newPalettePath: paletteFile.path);
        printy("Color Extracted From Image");
        return nc;
      } else {
        return null;
      }
    } catch (e) {
      await File(imagePath).deleteIfExists();
      return null;
    }
  }

  Future<void> reExtractTrackColorPalette({required Track track, required NamidaColor? newNC, required String? imagePath}) async {
    assert(newNC != null || imagePath != null, 'a color or imagePath must be provided');

    final paletteFile = File("${AppDirs.PALETTES}${track.filename}.palette");
    if (newNC != null) {
      await paletteFile.writeAsJson(newNC.toJson());
      _updateInColorMap(track.filename, newNC);
    } else if (imagePath != null) {
      final nc = await _extractPaletteFromImage(imagePath, forceReExtract: true);
      _updateInColorMap(imagePath.getFilenameWOExt, nc);
    }
    if (Player.inst.nowPlayingTrack == track) {
      updatePlayerColorFromTrack(track, null);
    }
  }

  Future<Iterable<Color>> _extractPaletteGenerator(String imagePath, {bool useIsolate = _defaultUseIsolate}) async {
    if (await File(imagePath).exists()) return [];
    const defaultTimeout = Duration(seconds: 5);
    if (!useIsolate) {
      final result = await PaletteGenerator.fromImageProvider(FileImage(File(imagePath)), filters: [], maximumColorCount: 28, timeout: defaultTimeout);
      return result.colors;
    } else {
      final imageProvider = FileImage(File(imagePath));
      final ImageStream stream = imageProvider.resolve(
        const ImageConfiguration(size: null, devicePixelRatio: 1.0),
      );
      final Completer<ui.Image> imageCompleter = Completer<ui.Image>();
      Timer? loadFailureTimeout;
      late ImageStreamListener listener;
      listener = ImageStreamListener((ImageInfo info, bool synchronousCall) {
        loadFailureTimeout?.cancel();
        stream.removeListener(listener);
        imageCompleter.complete(info.image);
      });
      if (defaultTimeout != Duration.zero) {
        loadFailureTimeout = Timer(defaultTimeout, () {
          stream.removeListener(listener);
          imageCompleter.completeError(
            TimeoutException('Timeout occurred trying to load from $imageProvider'),
          );
        });
      }
      stream.addListener(listener);
      final ui.Image image = await imageCompleter.future;
      final ByteData? imageData = await image.toByteData();
      if (imageData == null) return [];

      final encimg = EncodedImage(imageData, width: image.width, height: image.height);
      final colorValues = await _extractPaletteGeneratorCompute.thready(encimg);

      return colorValues.map((e) => Color(e));
    }
  }

  static Future<List<int>> _extractPaletteGeneratorCompute(EncodedImage encimg) async {
    final result = await PaletteGenerator.fromByteData(encimg, filters: [], maximumColorCount: 28);
    return result.colors.map((e) => e.value).toList();
  }

  void _updateInColorMap(String filenameWoExt, NamidaColor? nc) {
    if (nc != null) colorsMap[filenameWoExt] = nc;
  }

  void _updateCurrentPaletteHalfs(NamidaColor nc) {
    final halfIndex = (nc.palette.length - 1) / 3;
    paletteFirstHalf.clear();
    paletteSecondHalf.clear();

    nc.palette.loop((c, i) {
      if (i <= halfIndex) {
        paletteFirstHalf.add(c);
      } else {
        paletteSecondHalf.add(c);
      }
    });
  }

  Future<void> generateAllColorPalettes() async {
    await Directory(AppDirs.PALETTES).create();

    isGeneratingAllColorPalettes.value = true;
    for (int i = 0; i < allTracksInLibrary.length; i++) {
      if (!isGeneratingAllColorPalettes.value) break; // stops extracting
      await getTrackColors(allTracksInLibrary[i], useIsolate: true);
    }

    isGeneratingAllColorPalettes.value = false;
  }

  void stopGeneratingColorPalettes() => isGeneratingAllColorPalettes.value = false;

  static const _defaultUseIsolate = false;
}

extension ColorUtils on Color {
  Color get delightned {
    final hslColor = HSLColor.fromColor(this);
    final modifiedColor = hslColor.withLightness(0.4).toColor();
    return modifiedColor;
  }

  Color get lighter {
    final hslColor = HSLColor.fromColor(this);
    final modifiedColor = hslColor.withLightness(0.64).toColor();
    return modifiedColor;
  }
}
