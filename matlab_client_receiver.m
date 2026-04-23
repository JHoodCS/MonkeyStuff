% =======================================================================================
% BACKGROUND PIPE RECEIVER
%
% Usage:
%
%   matlab_client_receiver()                % start receiver
%   s = matlab_client_receiver('state');    % set up variable for accessing queue status
%   matlab_client_receiver('stop')          % stop receiver
%
%   s.contact                               % get number of items in queue
%
% =======================================================================================

function out = matlab_client_receiver(cmd)

persistent timerObj
PIPE_PATH = "/tmp/expo_matlab_from_client_pipe";

if nargin == 0
    cmd = "start";
end

switch lower(cmd)

% ================= START =================
case "start"

    if ~isempty(timerObj) && isvalid(timerObj)
        disp("Receiver already running");
        return;
    end

    fprintf("[CLIENT] Starting receiver...\n");

    % initialize state once
    state.contact = 0;
    setappdata(0,'CLIENT_STATE',state);

    timerObj = timer( ...
        'ExecutionMode','fixedSpacing', ...
        'Period',0.01, ...
        'BusyMode','drop', ...
        'TimerFcn',@read_pipe);

    start(timerObj);

    assignin('base','matlab_client_timer',timerObj);


% ================= STATE ACCESS =================
case "state"

    if isappdata(0,'CLIENT_STATE')
        out = getappdata(0,'CLIENT_STATE');
    else
        out.contact = 0;
    end


% ================= STOP =================
case "stop"

    if isempty(timerObj)
        return;
    end

    stop(timerObj);
    delete(timerObj);
    timerObj = [];

    rmappdata(0,'CLIENT_STATE');

    fprintf("[CLIENT] Receiver stopped\n");

otherwise
    error("Unknown command");
end



% =============================================================
% TIMER CALLBACK (BACKGROUND WORKER)
% =============================================================
function read_pipe(~,~)

persistent fid

if isempty(fid) || fid < 0
    fid = fopen(PIPE_PATH,'r');

    if fid < 0
        return
    end

    fprintf("[CLIENT] Pipe connected\n");
end

if feof(fid)
    return
end

[data,count] = fread(fid,4,'uint8=>uint8');

if count ~= 4
    return
end

value = typecast(uint8(data),'int32');

state = getappdata(0,'CLIENT_STATE');
state.contact = value;
setappdata(0,'CLIENT_STATE',state);

end

end
