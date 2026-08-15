import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/avatar_service.dart';
import '../../../core/config/app_theme.dart';

/// Renders one avatar (default illustrated SVG, or a user's uploaded photo
/// if [photoUrl] is provided — photo always takes priority over the SVG).
class AvatarView extends StatelessWidget {
  const AvatarView({super.key, this.avatarId, this.photoUrl, this.size = 64});

  final String? avatarId;
  final String? photoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (photoUrl != null && photoUrl!.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          photoUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _svgFallback(context),
        ),
      );
    }
    return _svgFallback(context);
  }

  Widget _svgFallback(BuildContext context) {
    final option =
        AvatarService.instance.byId(avatarId ?? '') ??
        AvatarService.catalog.first;
    return ClipOval(
      child: SvgPicture.asset(
        option.assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// Grid for choosing (or changing) a default illustrated avatar during
/// onboarding or from Settings > Profile. [initialGender] pre-filters the
/// grid to match the gender the user already selected in onboarding, but
/// every avatar stays tappable — gender-matching is a sensible default, not
/// a restriction.
class AvatarPicker extends StatefulWidget {
  const AvatarPicker({
    super.key,
    required this.onSelected,
    this.initialGender,
    this.selectedId,
  });

  final ValueChanged<AvatarOption> onSelected;
  final AvatarGender? initialGender;
  final String? selectedId;

  @override
  State<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<AvatarPicker> {
  late AvatarGender _filter = widget.initialGender ?? AvatarGender.male;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedId;
  }

  @override
  Widget build(BuildContext context) {
    final options = AvatarService.instance.forGender(_filter);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AvatarGender>(
          segments: const [
            ButtonSegment(value: AvatarGender.male, label: Text('Male style')),
            ButtonSegment(
              value: AvatarGender.female,
              label: Text('Female style'),
            ),
          ],
          selected: {_filter},
          onSelectionChanged: (s) => setState(() => _filter = s.first),
        ),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          children: options.map((option) {
            final selected = option.id == _selectedId;
            return GestureDetector(
              onTap: () {
                setState(() => _selectedId = option.id);
                widget.onSelected(option);
              },
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? AppColors.accent : Colors.transparent,
                    width: 3,
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: AvatarView(avatarId: option.id, size: 72),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
