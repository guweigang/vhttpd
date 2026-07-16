<?php
header('X-Test-Cgi: Hello');
echo "CGI Request successful!\n";
echo "REQUEST_URI: " . ($_SERVER['REQUEST_URI'] ?? '') . "\n";
echo "METHOD: " . ($_SERVER['REQUEST_METHOD'] ?? '') . "\n";
if (!empty($_GET)) {
    echo "GET PARAMS: " . json_encode($_GET) . "\n";
}
