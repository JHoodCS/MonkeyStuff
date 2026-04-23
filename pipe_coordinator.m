% =======================================================================================
% PIPE COORDINATOR
%
% Allows for easy starting and stopping of all MATLAB pipe communication
%
% Usage:
%
%   pipe_coordinator()                  % Start all pipes
%   pipe_coordinator(0)                 % Stop all pipes
%
%   (In reality, any input other than empty will stop all pipes)
%
% =======================================================================================


function pipe_coordinator(~)

    % Initialize if no arguments
    if nargin == 0
	    % Start RTOS pipe receiver
	    % matlab_rtos_receiver();
	
	    % Start Client pipe receiver and set variable for getting queue status
	    matlab_client_receiver();
        s = matlab_client_receiver('state');
	
	    % Start Client pipe sender
	    matlab_client_sender();
    
    % Assume shutdown command if any argument is passed
    else
        % Stop RTOS pipe receiver

        % Stop Client pipe receiver
        matlab_client_receiver('stop');

        % Client pipe sender auto exits
    end 

