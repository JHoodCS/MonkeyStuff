% =============================================================
% |                                                           |
% | SEND "IN CONTACT" STATUS TO CLIENT                        |
% |                                                           |
% |                                                           |
% | Usage:                                                    |
% |                                                           |
% | Satellite "In Contact":         matlab_client_sender(1)   |
% | Satellite "Not In Contact":     matlab_client_sender(0)   |
% =============================================================



function matlab_client_sender(bit)
    % Persistent Unix pipe writer
    %
    % matlab_client_sender()     -> initialize/open pipe
    % matlab_client_sender(1)    -> send 1
    % matlab_client_sender(0)    -> send 0

    persistent fid
    PIPE_PATH = '/tmp/expo_client_from_matlab_pipe';

    % ---------- INIT ----------
    if nargin == 0
        if isempty(fid) || fid == -1
            fid = fopen(PIPE_PATH,'w');

            if fid == -1
                error('Failed to open pipe');
            end

            fprintf('Pipe opened\n');
        end
        return;
    end

    % ---------- SEND ----------
    if isempty(fid) || fid == -1
        disp('Pipe not open');
        return;
    end

    if ~(bit == 0 || bit == 1)
        error('Argument must be 0 or 1');
    end

    n = fprintf(fid,'%d\n',bit);

    % ---------- READER EXITED ----------
    if n < 0
        warning('Reader disconnected');
        fclose(fid);
        fid = [];
    end
end

