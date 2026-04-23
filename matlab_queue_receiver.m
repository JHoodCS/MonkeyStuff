function matlab_queue_receiver()

PIPE_PATH = "/tmp/expo_matlab_from_client_pipe";

fprintf("[CLIENT] Opening pipe...\n");

fid = fopen(PIPE_PATH,'r');

if fid < 0
    error("Failed to open pipe");
end

cleanup = onCleanup(@() fclose(fid));

fprintf("[CLIENT] Connected\n");

while true
    [ok, value] = matlab_pipe_receive(fid);
    if ~ok
        break;
    end

    fprintf("[CLIENT] Received int: %d\n", value);
end

end


function [ok, value] = matlab_pipe_receive(fid)

% Read exactly 4 bytes (int32)
[data, count] = fread(fid, 4, 'uint8=>uint8');

if count ~= 4
    ok = false;
    value = [];
    return;
end

% Convert bytes → int32
value = typecast(uint8(data), 'int32');

ok = true;

end