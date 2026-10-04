// Product photos: resize in the browser, upload to the product-photos bucket.
// Each photo is stored twice: main (max 1200px) at "<SKU>/<id>.jpg" and a thumbnail
// (max 400px) at "<SKU>/<id>_t.jpg". products.photos stores only the main path;
// the thumbnail path is derived from it (Photos.thumbPath / Photos.thumbUrl).
(function () {
  const BUCKET = 'product-photos';
  const MAIN_PX = 1200;
  const THUMB_PX = 400;
  const QUALITY = 0.8;

  async function decode(file) {
    if (window.createImageBitmap) {
      try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch { /* fall back */ }
    }
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('Not an image: ' + file.name));
      img.src = URL.createObjectURL(file);
    });
  }

  // Returns a JPEG Blob no bigger than maxSide x maxSide (never enlarges).
  async function resize(file, maxSide, quality = QUALITY) {
    const src = file.width ? file : await decode(file);
    const w = src.width, h = src.height;
    const scale = Math.min(1, maxSide / Math.max(w, h));
    const cw = Math.max(1, Math.round(w * scale)), ch = Math.max(1, Math.round(h * scale));
    const canvas = document.createElement('canvas');
    canvas.width = cw; canvas.height = ch;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';               // transparent PNGs get a white background
    ctx.fillRect(0, 0, cw, ch);
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(src, 0, 0, cw, ch);
    const blob = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', quality));
    if (!blob) throw new Error('Could not convert image: ' + (file.name || ''));
    return blob;
  }

  function newId() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  }

  function thumbPath(path) {
    return String(path).replace(/\.jpg$/i, '_t.jpg');
  }

  // Resizes and uploads one photo for a product. Returns the main path.
  async function upload(sku, file) {
    const bitmap = await decode(file);
    const [main, thumb] = await Promise.all([resize(bitmap, MAIN_PX), resize(bitmap, THUMB_PX)]);
    if (bitmap.close) bitmap.close();
    const path = `${sku}/${newId()}.jpg`;
    const store = DB.client.storage.from(BUCKET);
    const opts = { contentType: 'image/jpeg', cacheControl: '31536000', upsert: false };
    const r1 = await store.upload(path, main, opts);
    if (r1.error) throw r1.error;
    const r2 = await store.upload(thumbPath(path), thumb, opts);
    if (r2.error) {
      await store.remove([path]);
      throw r2.error;
    }
    return path;
  }

  // Deletes photos (main + thumbnail) from storage. Only the web copies:
  // the original photos stay in Google Drive.
  async function remove(paths) {
    const list = (paths || []).flatMap((p) => [p, thumbPath(p)]);
    if (!list.length) return;
    const { error } = await DB.client.storage.from(BUCKET).remove(list);
    if (error) console.warn('Photo cleanup failed', error);
  }

  window.Photos = {
    MAIN_PX, THUMB_PX, resize, upload, remove, thumbPath,
    url: (path) => DB.photoUrl(path),
    thumbUrl: (path) => (path ? DB.photoUrl(thumbPath(path)) : ''),
  };
})();
