#!/usr/bin/php
<?php
error_reporting(E_ALL);
set_time_limit(0);
ob_implicit_flush();

# OS X only?
exec("ipconfig getifaddr en0", $host);
if (count($host) == 0) exec("ipconfig getifaddr en1", $host);

$host = $host[0];
$port    = 8888;
$master  = WebSocket($host, $port);
$sockets = array($master);
$users   = array();
$names   = array();
$rooms   = array("lobby");

while(true){
    $read = $sockets;
    socket_select($read, $write = NULL, $except = NULL, NULL);
    foreach ($read as $socket) {
        if ($socket == $master) {
            $client = socket_accept($master);
            if ($client < 0) {
                continue;
            } else {
                connect($client);
            }
        } else {
            $buffer = "";
            $bytes = socket_recv($socket, $buffer, 2048, 0);
            $user = getuser($socket);
            if ($bytes == 0) {
                echo "Sent blank. Forcing disconnect.\n"; # Anti-spam measure
                disconnect($user->socket);
            }
            if (!$user->handshake) {
                shake($user, $buffer);
            } else {
                $buffer = decode($buffer);
                if ($user->name == "") {
                    if (array_search($buffer, $names) !== FALSE) {
                        error($user, "Name already taken.");
                        break;
                    }
                    $user->name = $buffer;
                    $names[count($names)] = $buffer;
                    $buffer = $user->name." has joined the room.";
                    echo $user->name." has joined ".$user->room.".\n";
                    foreach ($users as $u) {
                        send($u, $buffer);
                    }
                } else if ($buffer == "/quit") {
                    $buffer = $user->name." has left the room.";
                    foreach ($users as $u) {
                        send($u, $buffer);
                    }
                    disconnect($user);
                } else {
                    foreach ($users as $u) {
                        broadcast($u, $buffer);
                    }
                }
            }
        }
    }
}

function send($user, $msg) {
    $msg = frame(json_encode(array('data' => $msg)));
    socket_write($user->socket, $msg, strlen($msg));
}

function broadcast($user, $msg) {
    $msg = frame(json_encode(array('user' => $user->name, 'data' => $msg)));
    socket_write($user->socket, $msg, strlen($msg));
}

function error($user, $msg){
    $msg = frame(json_encode(array('error' => $msg)));
    socket_write($user->socket, $msg, strlen($msg));
}

function frame($s) {
    $a = str_split($s, 125);
    if (count($a) == 1) return "\x81".chr(strlen($a[0])).$a[0];
    $ns = "";
    foreach ($a as $o) {
        $ns .= "\x81".chr(strlen($o)).$o;
    }
    return $ns;
}

function WebSocket($address, $port) {
    $master = socket_create(AF_INET, SOCK_STREAM, SOL_TCP);
    socket_set_option($master, SOL_SOCKET, SO_REUSEADDR, 1);
    socket_bind($master, $address, $port);
    socket_listen($master, 20);
    echo "Server started on ".$address.":".$port."\n";
    return $master;
}

function connect($socket) {
    global $sockets, $users, $rooms;
    $user = new User();
    $user->id = uniqid();
    $user->room = $rooms[0];
    $user->socket = $socket;
    array_push($users, $user);
    array_push($sockets, $socket);
}

function disconnect($user) {
    global $sockets, $users;
    for ($i = 0; $i < count($users); $i++) {
        if ($users[$i]->socket == $user->socket) {
            $found = $i;
            break;
        }
    }
    $index = array_search($user->socket, $sockets);
    socket_close($user->socket);
    array_splice($sockets, $index, 1);
    echo $user->name." has disconnected.\n";
    array_splice($users, $found, 1);
}

function shake($user, $buffer) {
    $key = substr($buffer, strpos($buffer, "Sec-WebSocket-Key: ")+19, 24);

    # Generate our Socket-Accept key based on the IETF specifications
    $key .= '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    $key = sha1($key, true);
    $key = base64_encode($key);

    $upgrade  = "HTTP/1.1 101 WebSocket Protocol Handshake\r\n".
                "Upgrade: websocket\r\n".
                "Connection: Upgrade\r\n".
                "Sec-WebSocket-Accept: $key\r\n\r\n";

    socket_write($user->socket, $upgrade, strlen($upgrade));
    $user->handshake = true;
    echo "Handshake with user ID #".$user->id." successful.\n";
    return true;
}

function getuser($socket) {
    global $users;
    foreach ($users as $user) {
        if ($user->socket == $socket) {
            return $user;
        }
    }
}

function decode($buffer) {
    $len = $masks = $data = $decoded = null;
    $len = ord($buffer[1]) & 127;

    if ($len === 126) {
        $masks = substr($buffer, 4, 4);
        $data = substr($buffer, 8);
    } else if ($len === 127) {
        $masks = substr($buffer, 10, 4);
        $data = substr($buffer, 14);
    } else {
        $masks = substr($buffer, 2, 4);
        $data = substr($buffer, 6);
    }
    for ($index = 0; $index < strlen($data); $index++) {
        $decoded .= $data[$index] ^ $masks[$index % 4];
    }
    return $decoded;
}

class User {
    var $id;
    var $name = "";
    var $socket;
    var $handshake;
    var $room;
}

?>
