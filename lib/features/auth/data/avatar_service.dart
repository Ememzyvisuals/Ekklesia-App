/// Catalog of Ekklesia's default illustrated avatars, assigned when a user
/// skips uploading a profile photo. Each is a flat-vector SVG bust portrait
/// (see assets/avatars/) in era-appropriate dress, matching the app's
/// Forest Green / Stone / Warm Gold palette — not a photo-realistic render,
/// by deliberate design (see build notes: painterly shading doesn't survive
/// translation to hand-authored SVG, so these are honest flat-vector art in
/// the same character styles rather than a fake "SVG" wrapper around raster
/// images).
enum AvatarGender { male, female }

class AvatarOption {
  const AvatarOption(
      {required this.id, required this.assetPath, required this.gender});
  final String id;
  final String assetPath;
  final AvatarGender gender;
}

class AvatarService {
  AvatarService._internal();
  static final AvatarService instance = AvatarService._internal();

  static const List<AvatarOption> catalog = [
    AvatarOption(
        id: 'male_01',
        assetPath: 'assets/avatars/avatar_male_01.svg',
        gender: AvatarGender.male),
    AvatarOption(
        id: 'male_02',
        assetPath: 'assets/avatars/avatar_male_02.svg',
        gender: AvatarGender.male),
    AvatarOption(
        id: 'male_03',
        assetPath: 'assets/avatars/avatar_male_03.svg',
        gender: AvatarGender.male),
    AvatarOption(
        id: 'female_01',
        assetPath: 'assets/avatars/avatar_female_01.svg',
        gender: AvatarGender.female),
    AvatarOption(
        id: 'female_02',
        assetPath: 'assets/avatars/avatar_female_02.svg',
        gender: AvatarGender.female),
    AvatarOption(
        id: 'female_03',
        assetPath: 'assets/avatars/avatar_female_03.svg',
        gender: AvatarGender.female),
  ];

  List<AvatarOption> forGender(AvatarGender gender) =>
      catalog.where((a) => a.gender == gender).toList();

  /// Deterministic pick from a stable seed (e.g. the local profile's
  /// display name — see onboarding_screen.dart) so re-running this (app
  /// restart, profile reload) always lands on the same avatar rather
  /// than reshuffling it on every rebuild. Users can still override via
  /// [byId] through the avatar picker UI.
  AvatarOption pickDefault(
      {required AvatarGender gender, required String seed}) {
    final options = forGender(gender);
    final index =
        seed.codeUnits.fold<int>(0, (sum, c) => sum + c) % options.length;
    return options[index];
  }

  AvatarOption? byId(String id) {
    for (final option in catalog) {
      if (option.id == id) return option;
    }
    return null;
  }
}
