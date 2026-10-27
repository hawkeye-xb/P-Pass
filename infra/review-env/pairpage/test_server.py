#!/usr/bin/env python3
"""配对页后端的示例图接口测试（#1088）：审核员相册为空时，从配对页下载示例图。

只测不依赖 daemon 的部分：示例图页、示例图文件、白名单外的路径一律 404。
跑法：python3 -B infra/review-env/pairpage/test_server.py（-B：不在仓库里留 __pycache__）
"""
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

SAMPLES = ["sample-1.jpg", "sample-2.jpg", "sample-3.jpg"]


class SamplesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as r:
                return r.status, r.headers.get("Content-Type", ""), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Content-Type", ""), e.read()

    def test_samples_page_lists_every_image(self):
        code, ctype, body = self.get("/samples")
        self.assertEqual(code, 200)
        self.assertTrue(ctype.startswith("text/html"), ctype)
        for name in SAMPLES:
            self.assertIn(f"/samples/{name}".encode(), body)

    def test_each_sample_is_a_jpeg(self):
        for name in SAMPLES:
            code, ctype, body = self.get(f"/samples/{name}")
            self.assertEqual(code, 200, name)
            self.assertEqual(ctype, "image/jpeg", name)
            self.assertEqual(body[:3], b"\xff\xd8\xff", name)

    def test_paths_outside_whitelist_are_404(self):
        for path in ["/samples/sample-4.jpg", "/samples/../server.py", "/samples/%2e%2e/server.py",
                     "/samples/index.html", "/samples/sample-1.png", "/samples/"]:
            code, _, _ = self.get(path)
            self.assertEqual(code, 404, path)

    def test_index_links_to_samples(self):
        code, _, body = self.get("/")
        self.assertEqual(code, 200)
        self.assertIn(b'href="/samples', body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
