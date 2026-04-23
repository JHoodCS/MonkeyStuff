%% ============================================================
%% HOW TO USE TELEMETRY
%% ============================================================

%% Anywhere in MATLAB:
%%      
%%      Make system state variable:         s = telemetry_state();
%%
%%      Access Mode:                        s.mode
%%      Access Active Tasks:                s.tasks
%%      Access Communication Frequency:     s.freq






%% ============================================================
%% ============================================================
%% Receiver Logic
%% ============================================================
%% ============================================================

function matlab_rtos_receiver()

PIPE_PATH = "/tmp/expo_matlab_from_rtos_pipe";

fprintf("[CLIENT] Opening pipe...\n");

fid = fopen(PIPE_PATH,'r');

if fid < 0
    error("Failed to open pipe");
end

cleanup = onCleanup(@() fclose(fid));

fprintf("[CLIENT] Connected\n");

while true
    if ~matlab_pipe_receive(fid)
        break;
    end
end

end


%% ============================================================
%% Receive Message
%% ============================================================

function ok = matlab_pipe_receive(fid)

% ---- read uint16 length header ----
[ok,len_bytes] = read_full(fid,2);
if ~ok
    return;
end

msg_len = typecast(uint8(len_bytes),'uint16');

EXPECTED = matlab_msg_size();

if msg_len ~= EXPECTED
    fprintf("[CLIENT] Bad size %u (expected %u)\n", ...
            msg_len, EXPECTED);
    ok = false;
    return;
end

% ---- read struct payload ----
[ok,payload] = read_full(fid,msg_len);
if ~ok
    return;
end

msg = decode_matlab_msg(payload);

%% ---- Handle message ----

switch msg.type

    case MATLAB_MODE()
        %fprintf("MODE: %s\n", satellite_mode_string(msg.data.mode));
        telemetry_state(struct("mode", msg.data.mode));

    case MATLAB_ACTIVE_TASKS()

        %fprintf("ACTIVE TASKS (%d):\n", msg.data.task_count);

        %for i=1:msg.data.task_count
        %    fprintf("  %s\n", msg.data.task_names{i});
        %end

        telemetry_state(struct("tasks", msg.data.task_names));

    case MATLAB_COMM_FREQ()
        %fprintf("COMM FREQ: %s\n", comm_freq_string(msg.data.freq));
        telemetry_state(struct("freq", msg.data.freq));

    otherwise
        fprintf("Unknown message type %d\n",msg.type);
end

ok = true;

end


%% ============================================================
%% Read Exact Bytes (C read_full)
%% ============================================================

function [ok,data] = read_full(fid,len)

[data,count] = fread(fid,len,'uint8=>uint8');

ok = (count == len);

if ~ok
    data=[];
end

end


%% ============================================================
%% Decode matlab_msg_t
%% ============================================================

function msg = decode_matlab_msg(bytes)

idx = 1;

% ---- TYPE (enum = 4 bytes) ----
msg.type = typecast(bytes(idx:idx+3),'uint32');
idx = idx + 4;

switch msg.type

    %% MODE MESSAGE
    case MATLAB_MODE()
        msg.data.mode = ...
            typecast(bytes(idx:idx+3),'uint32');

    %% COMM FREQ MESSAGE
    case MATLAB_COMM_FREQ()
        msg.data.freq = ...
            typecast(bytes(idx:idx+3),'uint32');

    %% ACTIVE TASKS MESSAGE
    case MATLAB_ACTIVE_TASKS()

        task_count = bytes(idx);
        idx = idx + 1;

        MAX_TASKS = 16;
        NAME_LEN  = 30;

        msg.data.task_count = task_count;
        msg.data.task_names = cell(task_count,1);

        for i=1:MAX_TASKS

            raw = bytes(idx:idx+NAME_LEN-1);
            idx = idx + NAME_LEN;

            if i <= task_count
                msg.data.task_names{i} = ...
                    char(raw(raw~=0))';
            end
        end

    otherwise
        msg.data=[];
end

end


%% ============================================================
%% Struct Size (matches sizeof(matlab_msg_t))
%% ============================================================

function s = matlab_msg_size()
s = 488;   % verified from C layout
end


%% ============================================================
%% Enum Constants
%% ============================================================

function v = MATLAB_MODE(),         v = uint32(0); end
function v = MATLAB_ACTIVE_TASKS(), v = uint32(1); end
function v = MATLAB_COMM_FREQ(),    v = uint32(2); end


%% ============================================================
%% Pretty Printers
%% ============================================================

function str = satellite_mode_string(v)

switch v
    case 0, str="BOOT";
    case 1, str="EARLY_ORBIT";
    case 2, str="NOMINAL";
    case 3, str="SAFE";
    otherwise, str="UNKNOWN";
end

end


function str = comm_freq_string(v)

switch v
    case 0, str="S_BAND";
    case 1, str="UHF_BAND";
    otherwise, str="UNKNOWN";
end

end



%% ============================================================
%% Shared Telemetry State
%% ============================================================

function state = telemetry_state(new_state)

persistent TELEMETRY

if isempty(TELEMETRY)
    TELEMETRY.mode  = [];
    TELEMETRY.tasks = {};
    TELEMETRY.freq  = [];
end

% ----- setter -----
if nargin == 1
    fields = fieldnames(new_state);

    for k = 1:numel(fields)
        TELEMETRY.(fields{k}) = new_state.(fields{k});
    end
end

% ----- getter -----
state = TELEMETRY;

end