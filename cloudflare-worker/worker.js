export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = url.searchParams.get("url");
    if (!target) {
      return new Response("Missing url param", { status: 400 });
    }

    let targetUrl;
    try {
      targetUrl = new URL(target);
    } catch (_) {
      return new Response("Invalid url param", { status: 400 });
    }

    const allowedOrigins = [
      "https://app.rakuten.co.jp",
      "https://img.travel.rakuten.co.jp",
      "https://travel.rakuten.co.jp",
    ];
    if (!allowedOrigins.includes(targetUrl.origin)) {
      return new Response("Forbidden", { status: 403 });
    }

    const upstream = await fetch(targetUrl.toString(), {
      headers: { "User-Agent": "ev-hotel-map-proxy" },
    });

    const headers = new Headers(upstream.headers);
    headers.set("access-control-allow-origin", "*");
    headers.set("access-control-allow-headers", "*");
    headers.set("access-control-allow-methods", "GET,OPTIONS");
    headers.delete("set-cookie");

    return new Response(upstream.body, { status: upstream.status, headers });
  },
};
