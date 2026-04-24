function out = matlab_state_client(cmd)
% ===========================================================================
% 
% MATLAB SHARED MEMORY STATE CLIENT
%
% Usage:
%
%   matlab_state_client()          -> initialize
%   matlab_state_client("close")   -> close handle
%
%
%   s = matlab_state_client("get") -> Get current state
%   (Do this before reading any values so that your data is up to date!)
%
%
%   "s.mode" 
%       returns the Mode as an int (see keys below)
%   "s.tasks" 
%       returns a string list of active tasks
%   "s.freq" 
%       returns the frequency as an int (see keys below)
%   "s.count" 
%       returns the number of messages in the satellite's transmission queue
%
% ===========================================================================
% 
% KEYS:
% 
%   Mode:
%      0 = BOOT MODE
%      1 = EARLY ORBIT MODE
%      2 = NOMINAL MODE
%      3 = PEAK MODE
%      4 = SAFE MODE
%
%   Frequency:
%      0 = S_BAND
%      1 = UHF_BAND
%
% ===========================================================================

    persistent shm

    % ---------------- INIT ----------------
    if nargin == 0
        shm.path = "\\wsl.localhost\Ubuntu\dev\shm\matlab_state.bin";
        shm.fid = fopen(shm.path,'r');

        if shm.fid < 0
            error("Failed to open shared memory");
        end

        shm.MAX_TASKS = 16;
        shm.TASK_NAME_LEN = 30;

        shm.size = 4 + 1 + 3 + ...
            shm.MAX_TASKS*shm.TASK_NAME_LEN + ...
            4 + 4;

        out = [];
        return;
    end

    if isempty(shm)
        error("Call matlab_state_client() first");
    end

    % ---------------- DISPATCH ----------------
    if isstring(cmd) || ischar(cmd)

        switch string(cmd)

            case "get"
                out = read_state(shm);

            case "close"
                fclose(shm.fid);
                shm = [];
                out = [];

            otherwise
                error("Unknown command: %s", cmd);
        end

    else
        error("Invalid input");
    end

end



% ============================================================
% INTERNAL READER (not exposed directly)
% ============================================================
function s = read_state(shm)

    fseek(shm.fid,0,'bof');
    raw = fread(shm.fid, shm.size, 'uint8=>uint8');

    i = 1;

    s.mode = typecast(raw(i:i+3),'int32'); i=i+4;

    task_count = raw(i); i=i+1;
    i=i+3;

    tasks = strings(1,task_count);

    for k=1:shm.MAX_TASKS

        name = raw(i:i+shm.TASK_NAME_LEN-1);
        i=i+shm.TASK_NAME_LEN;

        if k <= task_count
            z = find(name==0,1);
            if isempty(z), z = shm.TASK_NAME_LEN+1; end
            tasks(k) = string(char(name(1:z-1)'));
        end
    end

    s.tasks = tasks;

    s.freq  = typecast(raw(i:i+3),'int32'); i=i+4;
    s.count = typecast(raw(i:i+3),'int32');

end
