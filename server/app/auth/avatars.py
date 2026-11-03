"""Обработка аватара «как в Telegram»: центр-кроп до квадрата + сжатие в JPEG."""
import io

from PIL import Image, ImageOps

ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}


class InvalidImage(ValueError):
    pass


def process_avatar(data: bytes, *, output_size: int) -> bytes:
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as e:  # noqa: BLE001 — любой сбой разбора изображения
        raise InvalidImage("не удалось распознать изображение") from None
    if image.format not in ALLOWED_FORMATS:
        raise InvalidImage(f"неподдерживаемый формат: {image.format}")

    image = ImageOps.exif_transpose(image)  # учитываем поворот с камеры
    image = image.convert("RGB")

    w, h = image.size
    side = min(w, h)
    left, top = (w - side) // 2, (h - side) // 2
    image = image.crop((left, top, left + side, top + side))
    if side != output_size:
        image = image.resize((output_size, output_size), Image.LANCZOS)

    buf = io.BytesIO()
    image.save(buf, format="JPEG", quality=87, optimize=True)
    return buf.getvalue()
