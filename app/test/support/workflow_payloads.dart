/// The bodies `GET /api/v1/workflows` and `/workflows/{id}` actually return.
///
/// These are the three definitions in `workflows/examples/` as the gateway's
/// presentation views serve them (`docs/api.md`): `required` and `section` are
/// always present because `InputField.to_view` always writes them, and there is
/// no `bind`, no node id and no node type in any of it, because the binding
/// view is a separate object gateway-side.
///
/// They are written out as JSON rather than built by a helper on purpose. A
/// fixture assembled by the same code that reads it can make an assertion true
/// on its own; this one is the wire format, and if the gateway's shape ever
/// changes these are what stop matching.
library;

/// `GET /api/v1/workflows` for the three examples.
Map<String, Object?> examplesRegistry() => <String, Object?>{
  'workflows': <Object?>[
    _summaryOf(txt2imgDetail()),
    _summaryOf(img2imgDetail()),
    _summaryOf(videoDetail()),
  ],
};

/// The summary entry for one detail body: the detail view minus `inputs`.
Map<String, Object?> _summaryOf(Map<String, Object?> detail) {
  final summary = Map<String, Object?>.from(detail);
  summary.remove('inputs');
  return summary;
}

/// A registry made of exactly the workflows given.
Map<String, Object?> registryOf(List<Map<String, Object?>> details) =>
    <String, Object?>{
      'workflows': <Object?>[for (final detail in details) _summaryOf(detail)],
    };

Map<String, Object?> txt2imgDetail() => <String, Object?>{
  'id': 'example_txt2img',
  'name': 'Example Text to Image',
  'presentation': <String, Object?>{
    'group': 'Create',
    'category': 'Example',
    'badge': 'TXT2IMG',
    'short_description':
        'A prompt-only example showing the smallest complete workflow '
        'definition.',
    'how_to_use':
        'Describe what you want in the Prompt field. Everything else has a '
        'default that works, and lives under Advanced.',
    'input_summary': 'Prompt only',
    'example_prompt':
        'A rainy alley at night, cinematic lighting, wet asphalt reflections',
    'best_for': <Object?>[
      'Learning what a LocalCanvas workflow definition looks like',
      'Starting your own prompt-only workflow',
    ],
    'not_ideal_for': <Object?>[
      'Anything that starts from an existing image or video',
    ],
  },
  'required_media': <Object?>[],
  'input_summary': 'Prompt only',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
      'help': 'What you want to see.',
    },
    <String, Object?>{
      'id': 'negative_prompt',
      'label': 'Avoid',
      'type': 'multiline',
      'required': false,
      'section': 'advanced',
      'default': '',
      'help': 'What you do not want to see.',
    },
    <String, Object?>{
      'id': 'width',
      'label': 'Width',
      'type': 'integer',
      'required': false,
      'section': 'main',
      'default': 768,
      'min': 256,
      'max': 2048,
      'step': 64,
      'pair': 'width',
    },
    <String, Object?>{
      'id': 'height',
      'label': 'Height',
      'type': 'integer',
      'required': false,
      'section': 'main',
      'default': 768,
      'min': 256,
      'max': 2048,
      'step': 64,
      'pair': 'height',
    },
    <String, Object?>{
      'id': 'steps',
      'label': 'Steps',
      'type': 'integer',
      'required': false,
      'section': 'advanced',
      'default': 20,
      'min': 1,
      'max': 50,
      'help': 'More steps take longer and are not always better.',
    },
    <String, Object?>{
      'id': 'guidance',
      'label': 'Guidance',
      'type': 'float',
      'required': false,
      'section': 'advanced',
      'default': 6.0,
      'min': 1.0,
      'max': 20.0,
      'step': 0.5,
      'help': 'How closely the result follows the prompt.',
    },
    <String, Object?>{
      'id': 'sampler',
      'label': 'Sampler',
      'type': 'select',
      'required': false,
      'section': 'advanced',
      'default': 'euler',
      'options': <Object?>[
        <String, Object?>{'value': 'euler', 'label': 'Euler'},
        <String, Object?>{
          'value': 'euler_ancestral',
          'label': 'Euler ancestral',
        },
        <String, Object?>{'value': 'dpmpp_2m', 'label': 'DPM++ 2M'},
      ],
      'help': 'Use the samplers your own ComfyUI offers.',
    },
    <String, Object?>{
      'id': 'seed',
      'label': 'Seed',
      'type': 'integer',
      'required': false,
      'section': 'advanced',
      'default': 0,
      'min': 0,
      'max': 4294967295,
      'role': 'seed',
      'help':
          'The same seed with the same settings reproduces the same result.',
    },
  ],
};

Map<String, Object?> img2imgDetail() => <String, Object?>{
  'id': 'example_img2img',
  'name': 'Example Image to Image',
  'presentation': <String, Object?>{
    'group': 'Edit',
    'category': 'Example',
    'badge': 'IMG2IMG',
    'short_description':
        'An example that reworks a picture you choose, guided by a prompt.',
    'how_to_use':
        'Pick a picture, then describe what should change. Strength decides '
        'how far the result may travel from the original.',
    'input_summary': 'Image and prompt',
    'example_prompt': 'The same scene at golden hour, warm rim light',
    'best_for': <Object?>[
      'Learning how an image input is declared',
      'Restyling an existing picture',
    ],
    'not_ideal_for': <Object?>[
      'Generating from nothing - use the prompt-only example for that',
    ],
  },
  'required_media': <Object?>['image'],
  'input_summary': 'Image and prompt',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'source_image',
      'label': 'Source image',
      'type': 'image',
      'required': true,
      'section': 'main',
      'help': 'The picture to work from.',
    },
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
      'help': 'What the result should look like.',
    },
    <String, Object?>{
      'id': 'strength',
      'label': 'Strength',
      'type': 'float',
      'required': false,
      'section': 'main',
      'default': 0.55,
      'min': 0.0,
      'max': 1.0,
      'step': 0.05,
      'help': 'How much of the original may change.',
    },
    <String, Object?>{
      'id': 'output_name',
      'label': 'Output name',
      'type': 'string',
      'required': false,
      'section': 'advanced',
      'default': 'LocalCanvas',
      'help': 'The prefix your saved files get.',
    },
  ],
};

Map<String, Object?> videoDetail() => <String, Object?>{
  'id': 'example_video',
  'name': 'Example Video to Video',
  'presentation': <String, Object?>{
    'group': 'Video',
    'category': 'Example',
    'badge': 'VIDEO',
    'short_description':
        'An example that reworks a short clip you choose, guided by a prompt.',
    'how_to_use':
        'Pick a clip, describe what should change, and keep the frame count '
        'low while you are trying things out - video is slow.',
    'input_summary': 'Video and prompt',
    'example_prompt': 'The same shot as an ink drawing, strong outlines',
    'best_for': <Object?>[
      'Learning how a video input is declared',
      'Short clips of a few seconds',
    ],
    'not_ideal_for': <Object?>['Long clips', 'Anything you need quickly'],
  },
  'required_media': <Object?>['video'],
  'input_summary': 'Video and prompt',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'source_video',
      'label': 'Source clip',
      'type': 'video',
      'required': true,
      'section': 'main',
      'help': 'The clip to work from.',
    },
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
      'help': 'What the result should look like.',
    },
    <String, Object?>{
      'id': 'frames',
      'label': 'Frames',
      'type': 'integer',
      'required': false,
      'section': 'main',
      'default': 48,
      'min': 8,
      'max': 128,
      'step': 8,
      'help': 'How many frames of the clip to use.',
    },
    <String, Object?>{
      'id': 'loop',
      'label': 'Loop the result',
      'type': 'boolean',
      'required': false,
      'section': 'advanced',
      'default': false,
      'help': 'Write the clip so that it plays back as a loop.',
    },
  ],
};

/// A detail body carrying one field of every v0.1 type, for the form tests.
Map<String, Object?> allTypesDetail() => <String, Object?>{
  'id': 'all_types',
  'name': 'Every Field Type',
  'presentation': <String, Object?>{
    'group': 'Create',
    'badge': 'TXT2IMG',
    'short_description': 'One field of each type.',
  },
  'required_media': <Object?>['image'],
  'input_summary': 'A bit of everything',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'title',
      'label': 'Title',
      'type': 'string',
      'required': false,
      'section': 'main',
      'default': 'Untitled',
    },
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'steps',
      'label': 'Steps',
      'type': 'integer',
      'required': false,
      'section': 'main',
      'default': 20,
      'min': 1,
      'max': 50,
    },
    <String, Object?>{
      'id': 'strength',
      'label': 'Strength',
      'type': 'float',
      'required': false,
      'section': 'main',
      'default': 0.55,
      'min': 0.0,
      'max': 1.0,
      'step': 0.05,
    },
    <String, Object?>{
      'id': 'loop',
      'label': 'Loop the result',
      'type': 'boolean',
      'required': false,
      'section': 'main',
      'default': true,
    },
    <String, Object?>{
      'id': 'sampler',
      'label': 'Sampler',
      'type': 'select',
      'required': false,
      'section': 'main',
      'default': 'euler',
      'options': <Object?>[
        <String, Object?>{'value': 'euler', 'label': 'Euler'},
        <String, Object?>{'value': 'dpmpp_2m', 'label': 'DPM++ 2M'},
      ],
    },
    <String, Object?>{
      'id': 'source_image',
      'label': 'Source image',
      'type': 'image',
      'required': false,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'source_clip',
      'label': 'Source clip',
      'type': 'video',
      'required': false,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'seed',
      'label': 'Seed',
      'type': 'integer',
      'required': false,
      'section': 'advanced',
      'default': 0,
      'min': 0,
      'max': 4294967295,
      'role': 'seed',
    },
  ],
};

/// A detail body whose `select` carries more choices than a row of chips can
/// hold, and whose last field is a type this build has never heard of.
///
/// Both exist to be rendered: the first reaches the menu the chip row falls
/// back to, the second the placeholder that keeps a future schema honest.
/// A detail body whose Advanced section is deliberately awkward to group.
///
/// Two of its four advanced fields are of a type this build has never heard
/// of, so they fit no group the app knows and land in the catch-all — and they
/// are declared *first*, so a grouping that simply followed declaration order
/// would let them push the fields it did understand down the screen.
///
/// It also carries a `pair: width` with no partner and a one-line string, so
/// the section has three groups rather than one, and no group has more than
/// two fields in it. Nothing here may be dropped, hidden or reordered.
Map<String, Object?> oddAdvancedDetail() => <String, Object?>{
  'id': 'odd_advanced',
  'name': 'Odd Advanced',
  'presentation': <String, Object?>{
    'group': 'Create',
    'badge': 'TXT2IMG',
    'short_description': 'Advanced settings that fit no tidy group.',
  },
  'required_media': <Object?>[],
  'input_summary': 'Prompt only',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'region',
      'label': 'Region',
      // A type from a schema version later than this build.
      'type': 'mask',
      'required': false,
      'section': 'advanced',
    },
    <String, Object?>{
      'id': 'palette',
      'label': 'Palette',
      // And a second one, so the catch-all has an order to keep.
      'type': 'swatches',
      'required': false,
      'section': 'advanced',
    },
    <String, Object?>{
      'id': 'output_name',
      'label': 'Output name',
      'type': 'string',
      'required': false,
      'section': 'advanced',
      'default': 'LocalCanvas',
    },
    <String, Object?>{
      'id': 'only_width',
      'label': 'Width',
      'type': 'integer',
      'required': false,
      'section': 'advanced',
      'default': 768,
      'min': 256,
      'max': 2048,
      'step': 64,
      'pair': 'width',
    },
  ],
};

Map<String, Object?> awkwardFieldsDetail() => <String, Object?>{
  'id': 'awkward_fields',
  'name': 'Awkward Fields',
  'presentation': <String, Object?>{
    'group': 'Create',
    'badge': 'TXT2IMG',
    'short_description': 'A long list of choices and an input from the future.',
  },
  'required_media': <Object?>[],
  'input_summary': 'Prompt only',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'sampler',
      'label': 'Sampler',
      'type': 'select',
      'required': false,
      'section': 'main',
      'default': 'euler',
      'options': <Object?>[
        <String, Object?>{'value': 'euler', 'label': 'Euler'},
        <String, Object?>{'value': 'euler_ancestral', 'label': 'Euler ancestral'},
        <String, Object?>{'value': 'dpmpp_2m', 'label': 'DPM++ 2M'},
        <String, Object?>{'value': 'dpmpp_3m_sde', 'label': 'DPM++ 3M SDE'},
        <String, Object?>{'value': 'heun', 'label': 'Heun'},
        <String, Object?>{'value': 'lms', 'label': 'LMS'},
      ],
    },
    <String, Object?>{
      'id': 'region',
      'label': 'Region',
      // A type from a schema version later than this build.
      'type': 'mask',
      'required': true,
      'section': 'main',
      'help': 'Declared by a registry this app is older than.',
    },
  ],
};

/// A video workflow whose length field declares the rate it is played at.
///
/// The numbers are the schema contract's own worked example, and they are
/// chosen so that a naive `seconds * fps` is caught: 25..121 in steps of 4
/// never lands on 24, so at 24 fps a whole second is not an offerable length
/// at all, while 25, 29, 33 … frames are.
///
/// Everything else about it is an ordinary video workflow — including `fps`,
/// which is a normal integer field with no hint on it. Two fields are not
/// coupled here; one field is presented.
Map<String, Object?> videoLengthDetail() => <String, Object?>{
  'id': 'example_length',
  'name': 'Example Clip Length',
  'presentation': <String, Object?>{
    'group': 'Video',
    'category': 'Example',
    'badge': 'VIDEO',
    'short_description': 'A clip whose length is declared in frames.',
    'input_summary': 'Prompt and length',
  },
  'required_media': <Object?>[],
  'input_summary': 'Prompt and length',
  'inputs': <Object?>[
    <String, Object?>{
      'id': 'prompt',
      'label': 'Prompt',
      'type': 'multiline',
      'required': true,
      'section': 'main',
    },
    <String, Object?>{
      'id': 'length',
      'label': 'Length',
      'type': 'integer',
      'required': false,
      'section': 'main',
      'default': 25,
      'min': 25,
      'max': 121,
      'step': 4,
      'duration': <String, Object?>{'fps': 24},
      'help': 'How long the clip runs.',
    },
    <String, Object?>{
      'id': 'fps',
      'label': 'Frame rate',
      'type': 'integer',
      'required': false,
      'section': 'advanced',
      'default': 24,
      'min': 8,
      'max': 60,
    },
  ],
};

/// The same body with every `role`, `pair` and `duration` removed — the schema
/// as a renderer that ignores presentation hints receives it.
Map<String, Object?> withoutHints(Map<String, Object?> detail) {
  final copy = Map<String, Object?>.from(detail);
  final inputs = detail['inputs'];
  if (inputs is List) {
    copy['inputs'] = <Object?>[
      for (final field in inputs)
        if (field is Map<String, Object?>)
          (Map<String, Object?>.from(field)
            ..remove('role')
            ..remove('pair')
            ..remove('duration'))
        else
          field,
    ];
  }
  return copy;
}

/// The same body with only the `duration` blocks removed, so that a form with
/// the hint can be compared against the very same form without it.
Map<String, Object?> withoutDuration(Map<String, Object?> detail) {
  final copy = Map<String, Object?>.from(detail);
  final inputs = detail['inputs'];
  if (inputs is List) {
    copy['inputs'] = <Object?>[
      for (final field in inputs)
        if (field is Map<String, Object?>)
          (Map<String, Object?>.from(field)..remove('duration'))
        else
          field,
    ];
  }
  return copy;
}

/// The same body with a `duration` block written onto one field.
Map<String, Object?> withDuration(
  Map<String, Object?> detail,
  String fieldId,
  Object? duration,
) {
  final copy = Map<String, Object?>.from(detail);
  final inputs = detail['inputs'];
  if (inputs is List) {
    copy['inputs'] = <Object?>[
      for (final field in inputs)
        if (field is Map<String, Object?> && field['id'] == fieldId)
          (Map<String, Object?>.from(field)..['duration'] = duration)
        else
          field,
    ];
  }
  return copy;
}

/// The same body under a different id, name and group.
Map<String, Object?> renamed(
  Map<String, Object?> detail, {
  required String id,
  required String name,
  Object? group = _keep,
}) {
  final copy = Map<String, Object?>.from(detail);
  copy['id'] = id;
  copy['name'] = name;
  final presentation = Map<String, Object?>.from(
    (detail['presentation'] as Map?)?.cast<String, Object?>() ??
        <String, Object?>{},
  );
  if (!identical(group, _keep)) {
    if (group == null) {
      presentation.remove('group');
    } else {
      presentation['group'] = group;
    }
  }
  copy['presentation'] = presentation;
  return copy;
}

const Object _keep = Object();
