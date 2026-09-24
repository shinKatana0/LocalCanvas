"""The shipped example workflows explain themselves in the reader's language
wherever the vocabulary can (T-0147).

The examples are this repository's own prose, shipped to strangers, and the
first thing an unrelated ComfyUI user runs. T-0143 translates a hint only when
it is *exactly* the vocabulary's English for that field, so the examples'
hand-written hints were served in English in every locale.

The design decision (option b on the card): where the vocabulary has a
sentence for an example field, the example now carries that sentence verbatim,
and so translates like any generated hint. Where the vocabulary has nothing --
a source picture, a clip, an output name, a frame cap, motion, loop -- the
example keeps its own English, and this file says so rather than pretending
otherwise.

Every sentence is written out, not imported, for the reason
``test_api_workflow_language.py`` gives: a test that asked the module what it
says would agree with anything the module said.
"""

from __future__ import annotations

import shutil
from typing import Any, Dict

from conftest import EXAMPLES_ROOT

PROMPT_RU = "Опишите, что хотите увидеть. Чем больше подробностей, тем лучше."
NEGATIVE_RU = (
    "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум."
)
STEPS_RU = "Сколько труда вкладывается в результат. Больше шагов — больше деталей и ожидания."
CFG_RU = "Насколько точно выполняются ваши слова. Перебор делает картинку контрастной и грубой."
SAMPLER_RU = "Способ, которым строится картинка. У каждого немного свой вид."
SEED_RU = "Отправная точка для случайности. То же число повторяет тот же результат."
DENOISE_RU = "Насколько сильно перерисовать исходную картинку. Меньше — больше от неё останется."

PROMPT_EN = "Describe what you want to see. More detail gives more to go on."


def examples_gateway(gateway_factory, builder):
    """A gateway serving the repository's real example files, unmodified."""

    # The definitions and the API graphs they name: a definition whose graph is
    # missing is rejected at load, and the gateway then serves nothing to test.
    for source in sorted(EXAMPLES_ROOT.glob("*.yaml")) + sorted(EXAMPLES_ROOT.glob("*_api.json")):
        shutil.copyfile(source, builder.root / source.name)
    copied = sorted(p.name for p in builder.root.glob("*.yaml"))
    # Anchored: a moved examples directory would otherwise test nothing.
    assert copied == ["example_img2img.yaml", "example_txt2img.yaml", "example_video.yaml"]
    return gateway_factory()


def hints(harness, workflow_id: str, language: str) -> Dict[str, Any]:
    response = harness.client.get(
        f"/api/v1/workflows/{workflow_id}", headers={"Accept-Language": language}
    )
    assert response.status_code == 200, response.text
    return {
        field["id"]: field["help"]
        for field in response.json()["inputs"]
        if "help" in field
    }


def test_the_text_to_image_example_speaks_russian(gateway_factory, builder) -> None:
    harness = examples_gateway(gateway_factory, builder)
    assert hints(harness, "example_txt2img", "ru") == {
        "prompt": PROMPT_RU,
        "negative_prompt": NEGATIVE_RU,
        "steps": STEPS_RU,
        "guidance": CFG_RU,
        "sampler": SAMPLER_RU,
        "seed": SEED_RU,
    }


def test_the_image_to_image_example_speaks_russian_where_it_can(
    gateway_factory, builder
) -> None:
    """Two hints the vocabulary has nothing for stay the examples' own English."""

    harness = examples_gateway(gateway_factory, builder)
    assert hints(harness, "example_img2img", "ru") == {
        "source_image": "The picture to work from.",
        "prompt": PROMPT_RU,
        "strength": DENOISE_RU,
        "output_name": "The prefix your saved files get.",
    }


def test_the_video_example_speaks_russian_where_it_can(gateway_factory, builder) -> None:
    """Four of its five hints have no vocabulary sentence -- stated, not hidden."""

    harness = examples_gateway(gateway_factory, builder)
    assert hints(harness, "example_video", "ru") == {
        "source_video": "The clip to work from.",
        "prompt": PROMPT_RU,
        "frames": "How many frames of the clip to use. Fewer frames finish sooner.",
        "motion": "How much movement the result may invent.",
        "loop": "Write the clip so that it plays back as a loop.",
    }


def test_english_is_served_as_the_file_says(gateway_factory, builder) -> None:
    """The control: the Russian above came from translation, not from the files."""

    harness = examples_gateway(gateway_factory, builder)
    english = hints(harness, "example_txt2img", "en")
    assert english["prompt"] == PROMPT_EN
    assert english["prompt"] in (EXAMPLES_ROOT / "example_txt2img.yaml").read_text(
        encoding="utf-8"
    )
    assert PROMPT_RU not in (EXAMPLES_ROOT / "example_txt2img.yaml").read_text(
        encoding="utf-8"
    )
