class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


request = urllib.request.Request(
    'http://127.0.0.1:' + str(p['port']) + p['path'], method=p['method'])
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
try:
    response = opener.open(request, timeout=5)
except urllib.error.HTTPError as error:
    response = error
with response:
    body = response.read(1048577)
    if len(body) > 1048576:
        raise ValueError('business response too large')
    print(json.dumps(dict(status=response.code,
                         body=body.decode('utf-8', errors='replace'))))
