function mainCA()
%MAIN Slide-controlled mission viewer with a persistent center orbit scene.
%   Left/right columns change by slide while the center animation remains
%   fixed. External control inputs are stubbed for future integration.

    % Close all existing figure windows before starting fresh
    close all force;

    % =========================================================================
    % OPERATING MODE — mapped from numeric s.mode each frame.
    %   s.mode 0, 1  → animation paused; hold until mode 2, 3, or 4
    %   s.mode 2     → 'Nominal' (big_mat power rows 4 and 7)
    %   s.mode 3     → 'Peak'    (big_mat power rows 5 and 8)
    %   s.mode 4     → 'Safe'    (big_mat power rows 3 and 6)
    %
    % FREQUENCY (s.freq):
    %   s.freq 0     → S-band  (big_mat row 2)
    %   s.freq 1     → UHF     (big_mat row 1)
    % =========================================================================
    opMode = 'Nominal';  % default until first valid mode is received
    matlab_client_sender(); % SEDA: Initialized tx pipe
    matlab_state_client(); % SEDA: Initialized rx pipe

    % --- Data Loading ---
    % Find and load the simulation data file (big_mat.mat) from the same
    % directory as this script
    dataPath = locateNeighborFile('big_mat.mat');
    data = load(dataPath);
    if ~isfield(data, 'big_mat')
        error('The file big_mat.mat must contain a variable named big_mat.');
    end

    % Load the sample time vector from time.mat.  The variable inside must be
    % named 'time' and contain one timestamp (in seconds) per simulation sample,
    % matching the length of big_mat along the time dimension (dim 3).
    timePath = locateNeighborFile('time.mat');
    timeData = load(timePath);
    if ~isfield(timeData, 'time')
        error('time.mat must contain a variable named ''time''.');
    end
    rawTime = double(timeData.time(:).');  % ensure 1 x N row vector of seconds

    % Extract the main 3D data array: [numSims x numParams x numSteps]
    big_mat = data.big_mat;

    % Confirm the array has the required dimensions and channels
    validateBigMat(big_mat);

    % Upsample the data by 3x along the time axis to smooth animation playback
    big_mat = interpolateBigMat(big_mat, 3);

    % Interpolate the time vector to match the upsampled frame count so that
    % orbit.timeSec has one real timestamp per animation frame.
    nOrig      = numel(rawTime);
    nUpsampled = (nOrig - 1) * 3 + 1;
    xOld       = linspace(1, nOrig, nOrig);
    xNew       = linspace(1, nOrig, nUpsampled);
    upsampledTime = interp1(xOld, rawTime, xNew, 'pchip');

    % Store the interpolated data in global app state so helper functions
    % outside the main closure can access it without passing it as arguments
    setappdata(0, 'oksat_big_mat_runtime', big_mat);

    % --- Pre-computation ---
    % Extract satellite trajectory, ground station, altitude, etc. from row 9.
    % upsampledTime provides the real elapsed seconds for each animation frame.
    orbitData = extractOrbitData(big_mat, upsampledTime);

    % Build the color/font/style theme struct for dark-mode rendering
    theme = buildTheme();

    % Build a stub control config (placeholder for future C-pipe integration)
    % which provides mode labels, band selection, packet counts, genPower, and opMode
    controlConfig = loadControlStub(data, orbitData.numSteps, big_mat, opMode);

    % Build sunData directly from the sun XYZ vectors embedded in big_mat row 9,
    % cols 10-12. These are the authoritative sun positions that drive both the
    % 3D scene lighting and the battery charging model, so they must be kept in
    % sync rather than loaded from an optional external variable.
    sunData = buildSunDataFromOrbit(orbitData);

    % Build the 4-slide array, each slide defining left/right panel content
    slides = buildSlides(big_mat, orbitData, opMode);

    % --- Initial Animation State ---
    state.currSlide       = 1;
    state.frame           = orbitData.firstFrame;
    state.isPaused        = false;
    state.isRunning       = true;
    state.frameDelay      = 1 / 30;
    state.pendingSlideStep = 0;   % deferred slide direction (+1/-1) set by key callback

    % --- Figure Setup ---
    % Create the main figure window with a dark background, no menu/toolbar,
    % maximized, and register keyboard, close, and resize callbacks.
    %
    % MATLAB 2025 COMPATIBILITY NOTE:
    %   All panels and controls use 'pixels' units rather than 'normalized'.
    %   Mixing legacy uicontrol (normalized) with axes in a plain figure()
    %   triggers the new AxesLayoutManager unit-conversion pipeline on every
    %   pause()/drawnow call, causing the "Operation terminated by user" crash.
    %   Pixel units are resolved once and never touched by the layout manager.
    %   layoutPanels() recalculates pixel positions on window resize.
    fig = figure( ...
        'Name', 'OKSat Slide Controller', ...
        'NumberTitle', 'off', ...
        'Color', theme.figureColor, ...
        'MenuBar', 'none', ...
        'ToolBar', 'none', ...
        'WindowState', 'maximized', ...
        'WindowKeyPressFcn', @onKeyPress, ...
        'CloseRequestFcn',   @onClose, ...
        'SizeChangedFcn',    @onResize);

    % Create all panels and controls in pixel units — positions are applied
    % by layoutPanels() so the resize callback can reuse the same logic.
    pauseButton = uicontrol(fig, ...
        'Style',           'togglebutton', ...
        'String',          'Pause', ...
        'Units',           'pixels', ...
        'FontSize',        10, ...
        'FontWeight',      'bold', ...
        'BackgroundColor', [0.12 0.14 0.22], ...
        'ForegroundColor', [0.92 0.94 0.99], ...
        'Callback',        @onPauseToggle);

    titleLabel = uicontrol(fig, ...
        'Style',               'text', ...
        'String',              '', ...
        'Units',               'pixels', ...
        'FontSize',            15, ...
        'FontWeight',          'bold', ...
        'BackgroundColor',     theme.figureColor, ...
        'ForegroundColor',     theme.titleColor, ...
        'HorizontalAlignment', 'center');

    panelLeft = uipanel(fig, ...
        'Units',           'pixels', ...
        'BackgroundColor', theme.panelColor, ...
        'BorderType',      'line', ...
        'HighlightColor',  theme.panelEdgeColor, ...
        'BorderColor',     theme.panelEdgeColor);

    panelCenter = uipanel(fig, ...
        'Units',           'pixels', ...
        'BackgroundColor', theme.figureColor, ...
        'BorderType',      'none');

    panelRight = uipanel(fig, ...
        'Units',           'pixels', ...
        'BackgroundColor', theme.panelColor, ...
        'BorderType',      'line', ...
        'HighlightColor',  theme.panelEdgeColor, ...
        'BorderColor',     theme.panelEdgeColor);

    % Apply initial pixel positions based on the current figure size
    layoutPanels();

    % --- Graphics Initialization ---
    % Build the 3D orbit scene (stars, Earth, satellite, ground station, sun)
    graphics.center = initializeOrbitPanel(panelCenter, orbitData, sunData, theme);

    % Build the left/right column axes for the first slide
    graphics.slide  = initializeSlideColumns(state.currSlide);

    % Draw the very first frame before entering the animation loop
    renderFrame();

    % --- Main Animation Loop ---
    % Runs until the window is closed or the escape key is pressed
    while state.isRunning && ishandle(fig)
        tic;  % Start frame timer

        % ── Read live state from C pipe ───────────────────────────────────
        s = matlab_state_client("get");

        % mode 0 or 1 → hold animation paused until a valid mode arrives
        if s.mode == 0 || s.mode == 1
            state.isPaused = true;
        else
            state.isPaused = false;
            % Map numeric mode to opMode string
            %   2 → Nominal,  3 → Peak,  4 → Safe
            switch s.mode
                case 2,  opMode = 'Nominal';
                case 3,  opMode = 'Peak';
                case 4,  opMode = 'Safe';
            end
        end

        % freq 0 → S-band (big_mat row 2),  freq 1 → UHF (big_mat row 1)
        if s.freq == 0
            controlConfig.liveActiveBand = 'S-BAND';
        else
            controlConfig.liveActiveBand = 'UHF';
        end

        % Live packet count and task string from pipe
        controlConfig.livePacketCount = s.count;
        controlConfig.liveTasks       = s.tasks;

        % Propagate updated opMode into controlConfig for this frame
        controlConfig.opMode = opMode;
        % ─────────────────────────────────────────────────────────────────

        % Deferred slide change: key callback sets pendingSlideStep; we act
        % here, after the pipe read, so graphics handles are never modified
        % from within a drawnow-triggered callback (avoids re-entrancy crash
        % on Linux where X11 events fire immediately inside drawnow).
        if state.pendingSlideStep ~= 0
            state.currSlide        = mod(state.currSlide - 1 + state.pendingSlideStep, numel(slides)) + 1;
            graphics.slide         = initializeSlideColumns(state.currSlide);
            state.pendingSlideStep = 0;
        end

        renderFrame();         % Redraw all graphics for the current frame
        drawnow limitrate;     % Flush pending graphics events, rate-limited

        % Advance to the next valid frame only when not paused
        if ~state.isPaused
            state.frame = nextValidFrame(orbitData, state.frame);
        end

        % Sleep for the remainder of the frame budget to maintain target fps
        pause(max(0, state.frameDelay - toc));
    end

    % Clean up the figure if it still exists after the loop exits
    if ishandle(fig)
        delete(fig);
    end

    % =========================================================================
    %  NESTED HELPER FUNCTIONS (share the workspace of main())
    % =========================================================================

    % -------------------------------------------------------------------------
    % layoutPanels  –  Apply pixel positions to all panels and controls
    %
    % Called once at startup and again from onResize whenever the window
    % changes size.  All proportions match the original normalized layout:
    %   left panel  : x=1.5%  w=22.5%
    %   center panel: x=24.8% w=50.4%
    %   right panel : x=76.0% w=22.5%
    %   panels span : y=5%    h=90%
    %   top strip   : y=95.5% h=3%   (title label + pause button)
    % -------------------------------------------------------------------------
    function layoutPanels()
        if ~ishandle(fig)
            return;
        end
        fig.Units = 'pixels';
        fp = fig.Position;   % [left bottom width height] in pixels
        W  = fp(3);
        H  = fp(4);

        % Vertical zones (in pixels from bottom)
        panelBot = round(0.050 * H);
        panelH   = round(0.900 * H);
        stripBot = round(0.955 * H);
        stripH   = round(0.030 * H);

        % Horizontal zones
        lx = round(0.015 * W);   lw = round(0.225 * W);
        cx = round(0.248 * W);   cw = round(0.504 * W);
        rx = round(0.760 * W);   rw = round(0.225 * W);

        set(panelLeft,   'Position', [lx panelBot lw panelH]);
        set(panelCenter, 'Position', [cx panelBot cw panelH]);
        set(panelRight,  'Position', [rx panelBot rw panelH]);

        % Title label: centred between left and right panels
        set(titleLabel,  'Position', [cx stripBot cw stripH]);

        % Pause button: right-aligned in the top strip
        btnW = round(0.055 * W);
        set(pauseButton, 'Position', [W - btnW - round(0.005*W), stripBot, btnW, stripH]);
    end

    % -------------------------------------------------------------------------
    % onResize  –  SizeChangedFcn: reapply pixel layout when window resizes
    % -------------------------------------------------------------------------
    function onResize(~, ~)
        if ~state.isRunning
            return;
        end
        layoutPanels();
    end

    % -------------------------------------------------------------------------
    % initializeSlideColumns  –  (Re)build left and right panel axes for a slide
    %
    % Destroys any existing axes in the left/right panels and creates fresh ones
    % according to the item specifications stored in slides(slideIdx).
    % -------------------------------------------------------------------------
    function slideGraphics = initializeSlideColumns(slideIdx)
        % Clear all child objects (axes, text, etc.) from both side panels
        delete(allchild(panelLeft));
        delete(allchild(panelRight));

        % Create axes and graphics objects for the new slide's item lists
        slideGraphics.left  = initializeColumn(panelLeft,  slides(slideIdx).leftItems,  theme);
        slideGraphics.right = initializeColumn(panelRight, slides(slideIdx).rightItems, theme);
    end

    % -------------------------------------------------------------------------
    % initializeColumn  –  Stack multiple item axes vertically inside a panel
    %
    % Distributes the available panel height among items proportionally to
    % their heightWeight field, with a small gap between them.
    % -------------------------------------------------------------------------
    function items = initializeColumn(parentPanel, itemSpecs, themeValue)
        count      = numel(itemSpecs);
        gap        = 0.035;   % Normalized gap between adjacent items
        topMargin  = 0.03;    % Normalized margin at the top of the panel
        bottomMargin = 0.035; % Normalized margin at the bottom

        % Compute each item's share of the available height via its weight
        weights   = [itemSpecs.heightWeight];
        available = 1 - topMargin - bottomMargin - gap * max(0, count - 1);
        heights   = available * weights / sum(weights);
        items     = cell(1, count);

        % Lay items out top-to-bottom
        yTop = 1 - topMargin;
        for idx = 1:count
            height = heights(idx);
            y0 = yTop - height;

            % Create an axes for this item inside the parent panel
            ax = axes('Parent', parentPanel, ...
                'Units', 'normalized', ...
                'Position', [0.08 y0 0.86 height], ...
                'Color', themeValue.axesColor, ...
                'Box', 'on', ...
                'XColor', themeValue.axisColor, ...
                'YColor', themeValue.axisColor, ...
                'LineWidth', 0.9, ...
                'FontName', 'Helvetica', ...
                'FontSize', 10);

            % Populate the axes according to the item's kind
            itemStruct = initializeSlideItem(ax, itemSpecs(idx), themeValue);
            items{idx} = itemStruct;

            % Move the cursor down by the item height plus the gap
            yTop = y0 - gap;
        end
    end

    % -------------------------------------------------------------------------
    % initializeSlideItem  –  Dispatch to the correct item initializer by kind
    % -------------------------------------------------------------------------
    function item = initializeSlideItem(ax, spec, themeValue)
        switch spec.kind
            case {'timeseries', 'commEbNo', 'commLoss'}
                % Line-plot items that scroll with the animation frame
                item = initializeTimeSeriesItem(ax, spec, themeValue);
            case 'bar'
                % Single vertical bar chart (e.g. packet buffer fill level)
                item = initializeBarItem(ax, spec, themeValue);
            case {'text', 'placeholder'}
                % Text-only display (formatted metrics or static stub text)
                item = initializeTextItem(ax, spec, themeValue);
            otherwise
                error('Unsupported slide item kind: %s', spec.kind);
        end
    end

    % -------------------------------------------------------------------------
    % initializeTimeSeriesItem  –  Set up a multi-line scrolling time-series plot
    %
    % Creates the axes styling, a vertical cursor line, one colored line
    % per data series, a dot marker for the current sample, optional y-reference
    % line, and a legend.
    % -------------------------------------------------------------------------
    function item = initializeTimeSeriesItem(ax, spec, themeValue)
        hold(ax, 'on');
        grid(ax, 'on');

        % Dim the grid lines so data is the visual focus
        ax.GridAlpha      = 0.18;
        ax.GridColor      = themeValue.gridColor;
        ax.MinorGridAlpha = 0.12;
        ax.MinorGridColor = themeValue.gridColor;

        nLines = getSeriesCount(spec);

        % Store references needed for per-frame updates
        item.kind  = spec.kind;
        item.spec  = spec;
        item.ax    = ax;

        % Title text object (updated each frame for comm slides)
        item.title = title(ax, spec.title, ...
            'Color', themeValue.titleColor, ...
            'FontWeight', 'bold', ...
            'FontSize', 12);

        % Vertical dotted cursor line that moves to the current frame's x-value
        item.cursor = plot(ax, [1 1], [0 1], ':', ...
            'Color', themeValue.cursorColor, ...
            'LineWidth', 1.0);

        % Pre-allocate graphics arrays for line and marker handles
        item.lines   = gobjects(1, nLines);
        item.markers = gobjects(1, nLines);

        colors = spec.colors;
        for idx = 1:nLines
            % Determine line style: use spec.lineStyles if provided, else solid
            if ~isempty(spec.lineStyles) && idx <= numel(spec.lineStyles)
                lineStyle = spec.lineStyles{idx};
            else
                lineStyle = '-';
            end
            % History line
            item.lines(idx) = plot(ax, nan, nan, ...
                lineStyle, ...
                'Color', colors(idx, :), ...
                'LineWidth', 2.0);
            % Filled circle marker placed at the most recent valid sample;
            % hidden initially until the first frame is rendered
            item.markers(idx) = plot(ax, nan, nan, 'o', ...
                'MarkerFaceColor', colors(idx, :), ...
                'MarkerEdgeColor', blendColor(colors(idx, :), [1 1 1], 0.15), ...
                'MarkerSize', 5.0, ...
                'Visible', 'off');
        end

        % Set initial x-axis limits based on window mode.
        if strcmp(spec.xWindowMode, 'contact')
            % Size to the first contact window
            initLim = orbitData.contactWindowXLim(orbitData.firstFrame, :);
            xlim(ax, initLim);
        elseif spec.xWindowSize > 0
            xlim(ax, [spec.xData(1), spec.xData(1) + spec.xWindowSize]);
        else
            xlim(ax, [spec.xData(1), spec.xData(end)]);
        end
        ylim(ax, resolveSeriesLimits(spec, orbitData, controlConfig));
        ylabel(ax, spec.yLabel, 'Color', themeValue.labelColor, 'FontSize', 9);
        xlabel(ax, spec.xLabel, 'Color', themeValue.labelColor, 'FontSize', 9);
        % Optional horizontal reference line (e.g. minimum elevation threshold).
        % Created before the legend call so its handle can be included in the
        % legend entry — the inline label is suppressed (empty string) since
        % the legend itself carries the description.
        if isfield(spec, 'referenceY') && ~isempty(spec.referenceY)
            item.refLine = yline(ax, spec.referenceY, '--', '', ...
                'Color', [0.98 0.84 0.22], ...
                'LineWidth', 1.2, ...
                'FontSize', 10);
        else
            item.refLine = [];
        end

        % Build legend: data series lines, plus the reference line if present
        if ~isempty(item.refLine)
            allHandles = [item.lines, item.refLine];
            allLabels  = [spec.legendLabels, {spec.referenceLabel}];
        else
            allHandles = item.lines;
            allLabels  = spec.legendLabels;
        end
        legend(ax, allHandles, allLabels, ...
            'Location', 'northwest', ...
            'TextColor', themeValue.labelColor, ...
            'Color', themeValue.axesColor, ...
            'EdgeColor', themeValue.panelEdgeColor, ...
            'FontSize', 8);
        if ~spec.showLegend
            legend(ax, 'hide');
        end

        hold(ax, 'off');

        % Lock axis limits AFTER hold off and legend (both reset LimMode to auto).
        % Setting XLimMode/YLimMode to 'manual' directly is the only reliable way
        % to prevent MATLAB from auto-rescaling when new data is added to the lines.
        if spec.fixedYLimits
            ax.XLimMode = 'manual';
            ax.YLimMode = 'manual';
        end
    end

    % -------------------------------------------------------------------------
    % initializeBarItem  –  Set up a single vertical bar chart
    %
    % Used for scalar quantities like packet buffer fill count.
    % A floating value label is placed just above the bar top each frame.
    % -------------------------------------------------------------------------
    function item = initializeBarItem(ax, spec, themeValue)
        cla(ax);  % Clear any existing content

        item.kind  = spec.kind;
        item.spec  = spec;
        item.ax    = ax;
        item.title = title(ax, spec.title, ...
            'Color', themeValue.titleColor, ...
            'FontWeight', 'bold', ...
            'FontSize', 12);

        % Create a single bar starting at height 0; updated each frame
        item.bar = bar(ax, 1, 0, 0.55, ...
            'FaceColor', spec.barColor, ...
            'EdgeColor', blendColor(spec.barColor, [1 1 1], 0.18), ...
            'LineWidth', 1.0);

        % Constrain x-axis so the single bar is centred in the plot
        xlim(ax, [0.25 1.75]);
        ylim(ax, spec.yLimits);
        ylabel(ax, spec.yLabel, 'Color', themeValue.labelColor, 'FontSize', 9);

        % Replace numeric x-tick with the label string from the spec
        ax.XTick = 1;
        ax.XTickLabel = {spec.xLabel};
        ax.XTickLabelRotation = 0;
        ax.XColor = [0.92 0.94 0.99];  % Bright x-axis label
        ax.YColor = [0.92 0.94 0.99];  % Bright y-axis numbers
        grid(ax, 'on');
        ax.GridAlpha = 0.16;
        ax.GridColor = themeValue.gridColor;

        % Numeric value text rendered just above the bar top
        item.valueText = text(ax, 1, 0, '', ...
            'Color', [0.98 0.99 1.00], ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'bottom', ...
            'FontWeight', 'bold', ...
            'FontSize', 13);
    end

    % -------------------------------------------------------------------------
    % initializeTextItem  –  Set up a plain-text display panel
    %
    % Renders a bold title at the top and a multi-line body below it.
    % The axes box is hidden so it looks like a text card, not a plot.
    % -------------------------------------------------------------------------
    function item = initializeTextItem(ax, spec, themeValue)
        cla(ax);
        axis(ax, 'off');  % Hide axis lines/ticks for a text-card appearance

        item.kind  = spec.kind;
        item.spec  = spec;
        item.ax    = ax;

        % Bold title at the top of the card
        item.title = text(ax, 0.03, 0.95, spec.title, ...
            'Units', 'normalized', ...
            'Color', themeValue.titleColor, ...
            'FontWeight', 'bold', ...
            'FontSize', 12, ...
            'VerticalAlignment', 'top');

        % Body text rendered below the title; content is filled each frame.
        % bodyFont defaults to Helvetica; set to 'Courier New' on cards where
        % column alignment matters (e.g. the power load breakdown).
        item.body = text(ax, 0.03, 0.84, '', ...
            'Units', 'normalized', ...
            'Color', themeValue.labelColor, ...
            'FontName', spec.bodyFont, ...
            'FontSize', spec.bodyFontSize, ...
            'VerticalAlignment', 'top', ...
            'Interpreter', 'none');  % Disable TeX so special chars are literal
    end

    % -------------------------------------------------------------------------
    % initializeOrbitPanel  –  Build the persistent 3D orbit animation scene
    %
    % Creates a perspective 3D axes containing:
    %   - A random star field as scattered dots on a distant sphere
    %   - An Earth sphere (opaque blue) plus a semi-transparent atmosphere shell
    %   - A dotted equator ring for orientation
    %   - The satellite represented as a small sphere
    %   - An orbital trail (the last N frames of trajectory)
    %   - A ground station marker (green triangle)
    %   - A link line between satellite and ground station
    %   - A ground mask ring (optional per slide)
    %   - A sun sphere + glow halo + label that tracks the sun direction
    %   - Directional lighting (sun-side bright, fill light for detail)
    %   - A text overlay showing live telemetry in the corner
    % -------------------------------------------------------------------------
    function center = initializeOrbitPanel(parentPanel, orbit, sun, themeValue)
        % Create a 3D axes that fills the center panel
        ax = axes('Parent', parentPanel, ...
            'Position', [0.02 0.03 0.96 0.94], ...
            'Color', themeValue.figureColor, ...
            'XColor', 'none', ...   % Hide axis lines/labels for a clean look
            'YColor', 'none', ...
            'ZColor', 'none', ...
            'Projection', 'perspective', ...
            'DataAspectRatio', [1 1 1]);  % Equal scaling so sphere looks round
        hold(ax, 'on');

        % Set axis bounds and lock the 3D view aspect ratio to prevent distortion
        axis(ax, orbit.axisLimits);
        axis(ax, 'vis3d');

        % Set initial camera view: azimuth 36 deg, elevation 22 deg
        view(ax, 36, 22);

        % --- Star Field ---
        % Use a fixed random seed so the star pattern is deterministic
        rng(7);
        nStars = 950;

        % Generate random spherical coordinates for stars
        theta  = 2 * pi * rand(nStars, 1);       % Azimuth angle [0, 2pi]
        phi    = acos(2 * rand(nStars, 1) - 1);  % Polar angle for uniform distribution

        % Place stars just beyond the scene bounding sphere, with slight depth variation
        rStar  = orbit.sceneRadius * (1.18 + 0.42 * rand(nStars, 1));

        % Convert spherical to Cartesian and plot as small filled dots
        scatter3(ax, ...
            rStar .* sin(phi) .* cos(theta), ...
            rStar .* sin(phi) .* sin(theta), ...
            rStar .* cos(phi), ...
            1.0 + 4.0 * rand(nStars, 1), ...   % Random marker sizes
            repmat(themeValue.starColor, nStars, 1), ...
            'filled', ...
            'MarkerFaceAlpha', 0.45, ...
            'MarkerEdgeAlpha', 0.15);

        % --- Earth ---
        % Generate a unit sphere mesh, then scale to Earth radius
        [sx, sy, sz] = sphere(96);  % 96-segment sphere for smooth appearance

        % Opaque ocean-blue Earth with Gouraud lighting for smooth shading
        surf(ax, ...
            orbit.earthRadius * sx, ...
            orbit.earthRadius * sy, ...
            orbit.earthRadius * sz, ...
            'FaceColor', [0.08 0.28 0.63], ...
            'EdgeColor', 'none', ...
            'FaceLighting', 'gouraud', ...
            'AmbientStrength', 0.16, ...
            'DiffuseStrength', 0.86, ...
            'SpecularStrength', 0.28);

        % Semi-transparent atmosphere shell slightly larger than the Earth surface
        surf(ax, ...
            orbit.earthRadius * 1.026 * sx, ...
            orbit.earthRadius * 1.026 * sy, ...
            orbit.earthRadius * 1.026 * sz, ...
            'FaceColor', [0.34 0.60 0.96], ...
            'FaceAlpha', 0.10, ...
            'EdgeColor', 'none', ...
            'FaceLighting', 'gouraud');

        % Dotted equatorial ring for spatial orientation
        thetaEq = linspace(0, 2 * pi, 360);
        plot3(ax, ...
            orbit.earthRadius * cos(thetaEq), ...
            orbit.earthRadius * sin(thetaEq), ...
            zeros(size(thetaEq)), ...
            ':', ...
            'Color', [0.48 0.67 0.95], ...
            'LineWidth', 1.0);

        % --- Satellite ---
        % Start at the first valid frame position
        firstSat = orbit.satXYZ(orbit.firstFrame, :);
        firstGs  = orbit.gsXYZ(orbit.firstFrame, :);

        % Sphere mesh for the satellite body; radius proportional to scene scale
        [satX, satY, satZ] = sphere(28);
        satRadius = max(orbit.earthRadius * 0.028, orbit.sceneRadius * 0.012);

        % Store the surface handle so its XData/YData/ZData can be updated each frame
        center.satellite = surf(ax, ...
            satRadius * satX + firstSat(1), ...
            satRadius * satY + firstSat(2), ...
            satRadius * satZ + firstSat(3), ...
            'FaceColor', [1.00 0.82 0.15], ...  % Gold colour when in contact
            'EdgeColor', 'none', ...
            'FaceLighting', 'gouraud', ...
            'AmbientStrength', 0.25, ...
            'DiffuseStrength', 0.88, ...
            'SpecularStrength', 0.15);

        % Orbital trail: a line showing the last N frames of the trajectory
        center.trail = plot3(ax, firstSat(1), firstSat(2), firstSat(3), ...
            '-', ...
            'Color', [0.76 0.83 1.00], ...
            'LineWidth', 1.8);

        % --- Ground Station ---
        % Bright pentagram (5-pointed star) marker with a floating text label.
        % Both the marker and label are projected outward along the surface
        % normal so neither clips into the Earth sphere.
        gsMarkerOffset = orbit.earthRadius * 0.015;  % small lift to clear the surface
        gsLabelOffset  = orbit.earthRadius * 0.08;   % larger lift for the text
        gsMarkerPos    = firstGs + unitVector(firstGs) * gsMarkerOffset;
        gsLabelPos     = firstGs + unitVector(firstGs) * gsLabelOffset;

        center.groundStation = plot3(ax, ...
            gsMarkerPos(1), gsMarkerPos(2), gsMarkerPos(3), '.', ...
            'MarkerSize',      20, ...
            'Color',           [0.18 0.95 0.52]);

        center.groundStationLabel = text(ax, ...
            gsLabelPos(1), gsLabelPos(2), gsLabelPos(3), ...
            'Ground Station', ...
            'Color',               [0.18 0.95 0.52], ...
            'FontSize',            9, ...
            'FontWeight',          'bold', ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment',   'bottom');

        % Dashed line between satellite and ground station (colour changes with contact state)
        center.linkLine = plot3(ax, ...
            [firstSat(1) firstGs(1)], ...
            [firstSat(2) firstGs(2)], ...
            [firstSat(3) firstGs(3)], ...
            '--', ...
            'Color', [0.82 0.36 0.24], ...
            'LineWidth', 1.3);

        % Ground mask ring (circle on Earth's surface showing the contact footprint);
        % hidden by default and enabled only on slides where showGroundRing is true
        center.groundRing = plot3(ax, nan, nan, nan, ...
            '-', ...
            'Color', [0.82 0.36 0.24], ...
            'LineWidth', 1.7, ...
            'Visible', 'off');

        % --- Sun ---
        sunDir      = getSunDirection(sun, orbit.firstFrame);
        sunDistance = orbit.sceneRadius * 3.2;  % Place sun well outside the scene
        sunRadius   = orbit.sceneRadius * 0.10;
        sunCenter   = sunDir * sunDistance;

        [sunX, sunY, sunZ] = sphere(36);

        % Core sun sphere with flat self-illumination (no scene lighting applied)
        center.sun = surf(ax, ...
            sunRadius * sunX + sunCenter(1), ...
            sunRadius * sunY + sunCenter(2), ...
            sunRadius * sunZ + sunCenter(3), ...
            'FaceColor', [1.00 0.90 0.28], ...
            'EdgeColor', 'none', ...
            'FaceLighting', 'none', ...
            'AmbientStrength', 1.0);

        % Larger semi-transparent halo around the sun for a glow effect
        center.sunGlow = surf(ax, ...
            sunRadius * 1.9 * sunX + sunCenter(1), ...
            sunRadius * 1.9 * sunY + sunCenter(2), ...
            sunRadius * 1.9 * sunZ + sunCenter(3), ...
            'FaceColor', [1.00 0.82 0.16], ...
            'FaceAlpha', 0.10, ...
            'EdgeColor', 'none', ...
            'FaceLighting', 'none');


        % "EARTH" label above the Earth's north pole
        text(ax, 0, 0, orbit.earthRadius * 1.10, ...
            'EARTH', ...
            'Color', [0.69 0.81 1.00], ...
            'FontWeight', 'bold', ...
            'FontSize', 10, ...
            'HorizontalAlignment', 'center');


        title(ax, 'Persistent Orbit Animation', ...
            'Color', themeValue.titleColor, ...
            'FontWeight', 'bold', ...
            'FontSize', 15);

        % --- Lighting ---
        % Primary directional light from the sun position (warm colour)
        center.sunLight  = light(ax, 'Position', sunDir * orbit.sceneRadius * 4.0, ...
            'Style', 'infinite', ...
            'Color', [1.00 0.96 0.84]);
        % Dim fill light from the opposite side to keep night-side visible
        center.fillLight = light(ax, 'Position', -sunDir * orbit.sceneRadius * 2.0, ...
            'Style', 'infinite', ...
            'Color', [0.08 0.10 0.20]);
        lighting(ax, 'gouraud');  % Smooth per-vertex shading

        % Cache geometry data needed for per-frame position updates
        center.ax         = ax;
        center.sunDistance = sunDistance;
        center.sunRadius   = sunRadius;
        center.sunMesh     = struct('x', sunX, 'y', sunY, 'z', sunZ);
        center.satRadius   = satRadius;
        center.satMesh     = struct('x', satX, 'y', satY, 'z', satZ);
        hold(ax, 'off');
    end

    % -------------------------------------------------------------------------
    % renderFrame  –  Redraw every visible element for the current state
    %
    % Called once per iteration of the main loop (and on slide change or
    % pause toggle). Queries the external control stub, updates the left/right
    % column items, updates the 3D orbit panel, refreshes the pause button
    % label, and updates the figure super-title.
    % -------------------------------------------------------------------------
    function renderFrame()
        slideSpec    = slides(state.currSlide);

        % Get the external control state (band, mode, contact, packet count)
        % for the current frame from the stub (or future pipe reader)
        controlState = queryExternalControlStateStub(state.frame, orbitData, controlConfig);

        % Update left and right column items (time-series, bars, text)
        updateColumn(graphics.slide.left,  state.frame, controlState);
        updateColumn(graphics.slide.right, state.frame, controlState);

        % Update the 3D orbit scene (satellite position, trail, sun, info text)
        updateOrbitPanel(graphics.center, orbitData, sunData, state.frame, slideSpec, controlState);

        % Keep the pause button label in sync with the paused state
        set(pauseButton, 'Value', state.isPaused, ...
            'String', ternary(state.isPaused, 'Play', 'Pause'));

        % Update the foreground title label with the current slide name
        set(titleLabel, 'String', slideSpec.title);
    end

    % -------------------------------------------------------------------------
    % updateColumn  –  Update every item in a left or right column
    % -------------------------------------------------------------------------
    function updateColumn(items, frameIdx, controlState)
        for idx = 1:numel(items)
            updateSlideItem(items{idx}, frameIdx, controlState);
        end
    end

    % -------------------------------------------------------------------------
    % updateSlideItem  –  Dispatch per-frame update to the correct handler
    % -------------------------------------------------------------------------
    function updateSlideItem(item, frameIdx, controlState)
        switch item.kind
            case 'timeseries'
                % Standard time series: data and title come from the spec directly
                [seriesCell, titleText] = resolveTimeSeriesContent(item.spec, frameIdx, controlState);
                updateTimeSeriesItem(item, seriesCell, titleText, frameIdx);
            case 'commEbNo'
                % Communication Eb/No: active series depends on selected band
                [seriesCell, titleText] = resolveCommSeries(item.spec, controlState, 'ebno');
                updateTimeSeriesItem(item, seriesCell, titleText, frameIdx);
            case 'commLoss'
                % Communication link loss: active series depends on selected band
                [seriesCell, titleText] = resolveCommSeries(item.spec, controlState, 'loss');
                updateTimeSeriesItem(item, seriesCell, titleText, frameIdx);
            case 'bar'
                updateBarItem(item, frameIdx, controlState);
            case {'text', 'placeholder'}
                updateTextItem(item, frameIdx, controlState);
        end
    end

    % -------------------------------------------------------------------------
    % updateTimeSeriesItem  –  Advance time-series lines and cursor to frameIdx
    %
    % Recomputes y-limits from all visible data, repositions the vertical
    % cursor line at the current x-sample, draws data up to the current frame
    % on each line, and moves the dot marker to the last valid sample.
    % -------------------------------------------------------------------------
    function updateTimeSeriesItem(item, seriesCell, titleText, frameIdx)
        % Re-pin axis limits every frame for fixed items. MATLAB silently resets
        % XLimMode/YLimMode to 'auto' when plot data changes, so we must restore
        % 'manual' before doing anything else — this is the only reliable way to
        % prevent any rescaling.
        isContactMode = strcmp(item.spec.xWindowMode, 'contact');

        if item.spec.fixedYLimits
            item.ax.YLimMode = 'manual';
        end

        xNow = item.spec.xData(min(frameIdx, numel(item.spec.xData)));

        if isContactMode
            % X-axis shows exactly the current/next contact window.
            % Y-axis stays locked; only x updates each frame.
            winLim = orbitData.contactWindowXLim(min(frameIdx, orbitData.numSteps), :);
            item.ax.XLim = winLim;
            item.ax.XLimMode = 'manual';
            inWindow = item.spec.xData >= winLim(1) & item.spec.xData <= winLim(2);
        elseif item.spec.fixedYLimits
            item.ax.XLimMode = 'manual';
            inWindow = item.spec.xData >= item.ax.XLim(1) & ...
                       item.spec.xData <= item.ax.XLim(2);
        else
            % Dynamic: recompute y-limits and advance the paged x window
            yLimits = paddedLimitsFromCells(seriesCell);
            if diff(yLimits) <= eps
                yLimits = yLimits + [-1 1];
            end
            set(item.ax, 'YLim', yLimits);

            xStart = item.spec.xData(1);
            if item.spec.xWindowSize > 0
                W         = item.spec.xWindowSize;
                pageNum   = floor((xNow - xStart) / W);
                xWinStart = xStart + pageNum * W;
                xWinEnd   = xWinStart + W;
                set(item.ax, 'XLim', [xWinStart, xWinEnd]);
                inWindow  = item.spec.xData >= xWinStart & item.spec.xData <= xWinEnd;
            else
                inWindow  = true(1, numel(item.spec.xData));
            end
        end

        % Move the vertical cursor line to the current frame's x-position
        % Always read current axis y-limits for the cursor line so it spans
        % the full plot height whether or not fixedYLimits is active.
        yLimits = get(item.ax, 'YLim');
        set(item.cursor, 'XData', [xNow xNow], 'YData', yLimits);

        % Update the plot title (may change for comm slides when band switches)
        set(item.title, 'String', titleText);

        % Update each series line and its end-point dot marker
        for idx = 1:numel(item.lines)
            dataSeries = seriesCell{idx};

            % Intersect the visible window with samples up to the current frame
            upToNow   = false(1, numel(item.spec.xData));
            lastIdx   = min(frameIdx, numel(dataSeries));
            upToNow(1:lastIdx) = true;
            showMask  = inWindow & upToNow;

            xPlot = item.spec.xData(showMask);
            yPlot = dataSeries(showMask);

            set(item.lines(idx), 'XData', xPlot, 'YData', yPlot);

            % Place the dot marker at the last finite visible sample
            finiteShown = find(showMask & isfinite(dataSeries), 1, 'last');
            if isempty(finiteShown)
                set(item.markers(idx), 'Visible', 'off');
            else
                set(item.markers(idx), ...
                    'XData', item.spec.xData(finiteShown), ...
                    'YData', dataSeries(finiteShown), ...
                    'Visible', 'on');
            end
        end
    end

    % -------------------------------------------------------------------------
    % updateBarItem  –  Update the bar height and floating value label
    %
    % Dynamically expands the y-axis upper limit if the value exceeds the
    % preset maximum so the bar is never clipped.
    % -------------------------------------------------------------------------
    function updateBarItem(item, frameIdx, controlState)
        value = resolveBarValue(item.spec, frameIdx, controlState);

        % Clamp value to the fixed y-axis range
        yMin = item.spec.yLimits(1);
        yMax = item.spec.yLimits(2);
        value = min(max(value, yMin), yMax);

        % Set bar height to current value
        set(item.bar, 'YData', value);

        % Keep y-axis fixed at the spec limits — no auto-expand
        set(item.ax, 'YLim', [yMin yMax]);

        % Position the numeric label just above the bar top
        % Show as "value / max" to give buffer fill context
        labelOffset = 0.03 * (yMax - yMin);
        set(item.valueText, ...
            'Position', [1, min(value + labelOffset, yMax * 0.97), 0], ...
            'String', sprintf('%.0f / %.0f', value, yMax));
    end

    % -------------------------------------------------------------------------
    % updateTextItem  –  Refresh the body text of a text/placeholder card
    %
    % Placeholder items display static text; regular text items compute their
    % body content dynamically via buildTextBody.
    % -------------------------------------------------------------------------
    function updateTextItem(item, frameIdx, controlState)
        if strcmp(item.kind, 'placeholder')
            % Static stub text defined at slide-build time
            bodyText = item.spec.staticText;
        else
            % Dynamic text based on the item's textRole (e.g. orbital metrics)
            bodyText = buildTextBody(item.spec.textRole, frameIdx, controlState, orbitData);
        end
        set(item.body, 'String', bodyText);
    end

    % -------------------------------------------------------------------------
    % updateOrbitPanel  –  Move all animated 3D objects to match the current frame
    %
    % Updates:
    %   - Satellite sphere position
    %   - Orbital trail (sliding window of last N positions)
    %   - Sun sphere + glow + label + lighting (tracks sun direction series)
    %   - Ground station marker and link line visibility
    %   - Link line colour/style and satellite colour based on contact state
    %   - Ground mask ring (if enabled for this slide)
    %   - Info text overlay with live telemetry
    % -------------------------------------------------------------------------
    function updateOrbitPanel(center, orbit, sun, frameIdx, slideSpec, controlState)
        satPoint    = orbit.satXYZ(frameIdx, :);
        gsPoint     = orbit.gsXYZ(frameIdx, :);

        % Compute the start index for the orbital trail (sliding window)
        tailStart   = max(1, frameIdx - orbit.tailLength + 1);
        tailSegment = orbit.satXYZ(tailStart:frameIdx, :);

        % Get the sun direction unit vector for this frame
        sunDir    = getSunDirection(sun, frameIdx);
        sunCenter = sunDir * center.sunDistance;

        % Move the satellite sphere to the current position
        set(center.satellite, ...
            'XData', center.satRadius * center.satMesh.x + satPoint(1), ...
            'YData', center.satRadius * center.satMesh.y + satPoint(2), ...
            'ZData', center.satRadius * center.satMesh.z + satPoint(3));

        % Move the sun sphere and glow halo to track the evolving sun direction
        set(center.sun, ...
            'XData', center.sunRadius * center.sunMesh.x + sunCenter(1), ...
            'YData', center.sunRadius * center.sunMesh.y + sunCenter(2), ...
            'ZData', center.sunRadius * center.sunMesh.z + sunCenter(3));
        set(center.sunGlow, ...
            'XData', center.sunRadius * 1.9 * center.sunMesh.x + sunCenter(1), ...
            'YData', center.sunRadius * 1.9 * center.sunMesh.y + sunCenter(2), ...
            'ZData', center.sunRadius * 1.9 * center.sunMesh.z + sunCenter(3));


        % Update the directional lights to match the new sun position
        set(center.sunLight,  'Position',  sunDir * center.sunDistance);
        set(center.fillLight, 'Position', -sunDir * orbit.sceneRadius * 2.0);

        % Update the orbital trail with the current sliding window of positions
        set(center.trail, ...
            'XData', tailSegment(:, 1), ...
            'YData', tailSegment(:, 2), ...
            'ZData', tailSegment(:, 3));

        % Ground station marker is always shown when position data is valid.
        % The slant-range line is only drawn when the satellite is above the
        % horizon (elevation >= 0).
        elevationAboveHorizon = isfinite(orbit.elevation(frameIdx)) && ...
                                orbit.elevation(frameIdx) >= 0;
        if all(isfinite(gsPoint))
            gsNormal    = unitVector(gsPoint);
            gsMarkerPos = gsPoint + gsNormal * orbit.earthRadius * 0.015;
            gsLabelPos  = gsPoint + gsNormal * orbit.earthRadius * 0.08;
            set(center.groundStation, ...
                'XData', gsMarkerPos(1), ...
                'YData', gsMarkerPos(2), ...
                'ZData', gsMarkerPos(3), ...
                'Visible', 'on');
            set(center.groundStationLabel, ...
                'Position', gsLabelPos, ...
                'Visible', 'on');
        else
            set(center.groundStation,      'Visible', 'off');
            set(center.groundStationLabel, 'Visible', 'off');
        end

        if all(isfinite(gsPoint)) && elevationAboveHorizon
            set(center.linkLine, ...
                'XData', [satPoint(1) gsPoint(1)], ...
                'YData', [satPoint(2) gsPoint(2)], ...
                'ZData', [satPoint(3) gsPoint(3)], ...
                'Visible', 'on');
        else
            set(center.linkLine, 'Visible', 'off');
        end

        % Set link line and satellite colour based on whether contact is active:
        %   in-contact  → green link, gold satellite
        %   no contact  → orange/red dashed link, grey satellite
        if controlState.isInContact
            linkColor = [0.18 0.84 0.46];
            satColor  = [1.00 0.84 0.16];
        else
            linkColor = [0.82 0.36 0.24];
            satColor  = [0.50 0.55 0.69];
        end

        set(center.linkLine, ...
            'Color',     linkColor, ...
            'LineStyle', ternary(controlState.isInContact, '-', '--'), ...
            'LineWidth', ternary(controlState.isInContact, 1.8, 1.3));
        set(center.satellite, 'FaceColor', satColor);

        % Draw the ground mask ring if this slide requests it and the ground
        % station position is valid
        if slideSpec.showGroundRing && all(isfinite(gsPoint))
            ringXYZ = buildGroundStationRing(gsPoint, orbit.earthRadius, orbit.altitude(frameIdx), 10);
            set(center.groundRing, ...
                'XData',   ringXYZ(:, 1), ...
                'YData',   ringXYZ(:, 2), ...
                'ZData',   ringXYZ(:, 3), ...
                'Color',   linkColor, ...
                'Visible', 'on');
        else
            set(center.groundRing, 'Visible', 'off');
        end

        end

    % -------------------------------------------------------------------------
    % stepSlide  –  Advance to the next or previous slide
    %
    % direction: +1 = forward, -1 = backward; wraps around cyclically.
    % -------------------------------------------------------------------------
    function stepSlide(direction)
        % Set the pending slide direction; the main loop will apply it at a
        % safe point after the pipe read, avoiding re-entrancy on Linux.
        % Only honour the request if no step is already queued.
        if state.pendingSlideStep == 0
            state.pendingSlideStep = direction;
        end
    end

    % -------------------------------------------------------------------------
    % onPauseToggle  –  Callback for the Pause/Play toggle button
    % -------------------------------------------------------------------------
    function onPauseToggle(src, ~)
        % Read the toggle button's current value (1 = pressed = paused)
        state.isPaused = logical(get(src, 'Value'));
        renderFrame();  % Refresh button label immediately
    end

    % -------------------------------------------------------------------------
    % onKeyPress  –  Keyboard shortcut handler
    %
    %   Right arrow  →  next slide
    %   Left arrow   →  previous slide
    %   Space        →  toggle pause
    %   Home         →  jump back to the first valid frame
    %   Escape       →  close the window
    % -------------------------------------------------------------------------
    function onKeyPress(~, event)
        % Guard: ignore callbacks that arrive after the figure is deleted
        % (can happen on Linux when a key is held during shutdown)
        if ~state.isRunning || ~ishandle(fig)
            return;
        end
        switch event.Key
            case 'rightarrow'
                stepSlide(1);
            case 'leftarrow'
                stepSlide(-1);
            case 'space'
                % Space toggling is lightweight — safe to apply immediately
                state.isPaused = ~state.isPaused;
            case 'home'
                state.frame = orbitData.firstFrame;
            case 'escape'
                onClose(fig, []);
        end
    end

    % -------------------------------------------------------------------------
    % onClose  –  Window close callback
    %
    % Sets the keep-alive flag to false so the animation loop exits cleanly,
    % then deletes the figure if it still exists.
    % -------------------------------------------------------------------------
    function onClose(src, ~)
        state.isRunning = false;
        if ishandle(src)
            delete(src);
        end
    end
end

% =============================================================================
%  MODULE-LEVEL FUNCTIONS (not nested; no access to main() workspace)
% =============================================================================

% -----------------------------------------------------------------------------
% validateBigMat  –  Guard against malformed input data
%
% Checks that big_mat is a 3-D array and has the minimum number of simulations
% and parameter channels required by the orbit extraction code.
% -----------------------------------------------------------------------------
function validateBigMat(big_mat)
    if ndims(big_mat) ~= 3
        error('big_mat must be a 3D array shaped as [numsims, Lmax, numsteps].');
    end

    % Simulation index 9 is the geometry/orbit simulation; it needs at least
    % 16 parameter columns:
    %   1-3  sat XYZ,  4-6 vel XYZ,  7-9 GS XYZ,  10-12 sun XYZ,
    %   13 earth radius,  14 altitude,  15 inclination,  16 min elevation
    if size(big_mat, 1) < 9 || size(big_mat, 2) < 16
        error('big_mat is missing required simulation 9 geometry channels.');
    end
end

% -----------------------------------------------------------------------------
% locateNeighborFile  –  Resolve a filename relative to this script's directory
%
% Returns the full path and errors if the file does not exist.
% -----------------------------------------------------------------------------
function pathValue = locateNeighborFile(fileName)
    scriptDir = fileparts(mfilename('fullpath'));
    pathValue = fullfile(scriptDir, fileName);
    if ~exist(pathValue, 'file')
        error('Expected to find %s next to main.m.', fileName);
    end
end

% -----------------------------------------------------------------------------
% buildTheme  –  Return a struct of RGB colour values for the dark UI theme
% -----------------------------------------------------------------------------
function theme = buildTheme()
    theme = struct( ...
        'figureColor',   [0.01 0.01 0.06], ...  % Near-black figure background
        'panelColor',    [0.04 0.05 0.11], ...  % Slightly lighter panel background
        'axesColor',     [0.06 0.07 0.14], ...  % Axes background
        'panelEdgeColor',[0.16 0.18 0.30], ...  % Panel border lines
        'gridColor',     [0.40 0.45 0.62], ...  % Grid line colour
        'axisColor',     [0.55 0.60 0.76], ...  % Tick mark and axis line colour
        'labelColor',    [0.82 0.85 0.93], ...  % Axis label and body text colour
        'titleColor',    [0.92 0.94 0.99], ...  % Title text colour
        'cursorColor',   [0.88 0.92 1.00], ...  % Vertical cursor line colour
        'starColor',     [0.93 0.95 1.00]);      % Star dot colour
end

% -----------------------------------------------------------------------------
% interpolateBigMat  –  Upsample the time axis of big_mat for smoother playback
%INTERPOLATEBIGMAT Densify continuous channels to smooth playback.
%
% Each channel is resampled from numSteps to
%   (numSteps - 1) * upsampleFactor + 1
% frames using pchip (smooth) or nearest-neighbour (boolean/discrete) splines.
% -----------------------------------------------------------------------------
function big_mat_out = interpolateBigMat(big_mat_in, upsampleFactor)

    % If no upsampling is requested, pass through unchanged
    if upsampleFactor <= 1
        big_mat_out = big_mat_in;
        return;
    end

    [numSims, lMax, numSteps] = size(big_mat_in);

    % Number of output frames: endpoints preserved, gaps filled
    denseSteps = (numSteps - 1) * upsampleFactor + 1;

    % Original and new sample position vectors for interp1
    xOld = 1:numSteps;
    xNew = linspace(1, numSteps, denseSteps);

    big_mat_out = nan(numSims, lMax, denseSteps);
    for simIdx = 1:numSims
        for paramIdx = 1:lMax
            values = squeeze(big_mat_in(simIdx, paramIdx, :)).';
            big_mat_out(simIdx, paramIdx, :) = interpolateChannel(values, xOld, xNew, simIdx, paramIdx);
        end
    end
end

% -----------------------------------------------------------------------------
% interpolateChannel  –  Resample a single 1-D data channel
%
% Handles channels with no valid data, a single valid sample (constant fill),
% or multiple valid samples (smooth or nearest-neighbour interpolation).
% -----------------------------------------------------------------------------
function valuesOut = interpolateChannel(valuesIn, xOld, xNew, simIdx, paramIdx)
    valuesOut = nan(1, numel(xNew));
    validMask = isfinite(valuesIn);

    % Channel is entirely NaN — leave output as NaN
    if ~any(validMask)
        return;
    end

    % Only one valid sample — broadcast it to all output frames
    if nnz(validMask) == 1
        valuesOut(:) = valuesIn(find(validMask, 1, 'first'));
        return;
    end

    % Choose the interpolation method for this channel
    method    = interpolationMethodForChannel(simIdx, paramIdx);
    valuesOut = interp1(xOld(validMask), valuesIn(validMask), xNew, method, 'extrap');

    % Round nearest-neighbour output to keep boolean/integer channels discrete
    if strcmp(method, 'nearest')
        valuesOut = round(valuesOut);
    end
end

% -----------------------------------------------------------------------------
% interpolationMethodForChannel  –  Select interp1 method by channel identity
%
% Simulation rows 1 and 2, parameter 9 (contact flag) are boolean and must
% use nearest-neighbour interpolation. All other channels use pchip (smooth).
% -----------------------------------------------------------------------------
function method = interpolationMethodForChannel(simIdx, paramIdx)
    method = 'pchip';  % Default: shape-preserving piecewise cubic Hermite
    if any(simIdx == [1 2]) && paramIdx == 9
        % Contact flag is 0/1 — use nearest-neighbour to preserve hard edges
        method = 'nearest';
    end
end

% -----------------------------------------------------------------------------
% getRuntimeBigMat  –  Retrieve the interpolated big_mat from global app state
%
% Falls back to reloading from disk if the app-data entry is missing (e.g. if
% this function is called from a context where main() was not the entry point).
% -----------------------------------------------------------------------------
function big_mat = getRuntimeBigMat()
    big_mat = getappdata(0, 'oksat_big_mat_runtime');
    if isempty(big_mat)
        % Reload and cache as a fallback
        dataPath = locateNeighborFile('big_mat.mat');
        loaded   = load(dataPath, 'big_mat');
        big_mat  = loaded.big_mat;
        setappdata(0, 'oksat_big_mat_runtime', big_mat);
    end
end

% -----------------------------------------------------------------------------
% loadControlStub  –  Placeholder for future external control pipe integration
%LOADCONTROLSTUB Future staging point for C-pipe driven mode/frequency data.
%   Replace the default series below with values read from the external pipe.
%
% Currently fills all frames with the string 'STUB: MODE FROM PIPE' and 'AUTO'
% band selection. packetCount is loaded from the .mat if available.
% -----------------------------------------------------------------------------
function controlConfig = loadControlStub(data, numSteps, big_mat, opMode)
    % Placeholder mode labels — replace with pipe-read values when integrating
    controlConfig.stubModeLabel     = repmat({'STUB: MODE FROM PIPE'}, 1, numSteps);

    % Set the active band for all frames. Change this one value to switch
    % between simulations: 'S-BAND' reads big_mat row 2, 'UHF' reads row 1.
    % 'AUTO' infers from contact flags (legacy behaviour).
    ACTIVE_BAND = 'S-BAND';
    controlConfig.stubCommSelection = repmat({ACTIVE_BAND}, 1, numSteps);

    % Live fields updated every loop from the C pipe.
    % Initialised here so queryExternalControlStateStub can read them safely
    % before the first pipe read completes.
    controlConfig.liveActiveBand  = ACTIVE_BAND;  % overridden by s.freq each loop
    controlConfig.livePacketCount = 0;             % overridden by s.count each loop
    controlConfig.liveTasks       = '';            % overridden by s.tasks each loop

    % Optional per-frame packet count; fills with 0 if not in the .mat file.
    % 'previous' method holds the last known value forward over gaps.
    controlConfig.packetCount = loadOptionalNumericSeries(data, 'packetCount', numSteps, 0, 'previous');

    % Generated power series (W) from sim row 3, param 2 — solar-geometry driven,
    % mode-independent. Used by the power slide to determine BPX heater state.
    controlConfig.genPower = safeSeries(big_mat, 3, 2);

    % Operating mode string carried through so buildTextBody can branch on it
    controlConfig.opMode = opMode;

    % --- Thermal data (rows 6-8 = safe/nominal/peak) ---
    % Static irradiance constants — scalar, taken from frame 1
    controlConfig.thermalMaxIrradiance = selectFiniteScalar(squeeze(big_mat(6, 1, :)), 0);
    controlConfig.thermalMinIrradiance = selectFiniteScalar(squeeze(big_mat(6, 2, :)), 0);
    controlConfig.thermalAvgIrradiance = selectFiniteScalar(squeeze(big_mat(6, 3, :)), 0);

    % Dynamic thermal power series per mode [1 x numSteps] (W/m^2)
    controlConfig.thermalPowerSafe    = safeSeries(big_mat, 6, 4);
    controlConfig.thermalPowerNominal = safeSeries(big_mat, 7, 4);
    controlConfig.thermalPowerPeak    = safeSeries(big_mat, 8, 4);

    % Mass series per mode [1 x numSteps] — without and with payload
    controlConfig.massWithoutPayloadSafe    = safeSeries(big_mat, 6, 5);
    controlConfig.massWithoutPayloadNominal = safeSeries(big_mat, 7, 5);
    controlConfig.massWithoutPayloadPeak    = safeSeries(big_mat, 8, 5);
    controlConfig.massWithPayloadSafe       = safeSeries(big_mat, 6, 6);
    controlConfig.massWithPayloadNominal    = safeSeries(big_mat, 7, 6);
    controlConfig.massWithPayloadPeak       = safeSeries(big_mat, 8, 6);

    % --- Wireless communications data (rows 1=UHF, 2=S-band) ---
    % Carrier-to-noise ratio: param 3 = uplink C/N, param 4 = downlink C/N (dB)
    controlConfig.uhfCNUplink     = safeSeries(big_mat, 1, 3);
    controlConfig.uhfCNDownlink   = safeSeries(big_mat, 1, 4);
    controlConfig.sbandCNUplink   = safeSeries(big_mat, 2, 3);
    controlConfig.sbandCNDownlink = safeSeries(big_mat, 2, 4);

    % Received power: param 5 = at ground station, param 6 = at satellite (dBW)
    controlConfig.uhfRxPowerGS    = safeSeries(big_mat, 1, 5);
    controlConfig.uhfRxPowerSat   = safeSeries(big_mat, 1, 6);
    controlConfig.sbandRxPowerGS  = safeSeries(big_mat, 2, 5);
    controlConfig.sbandRxPowerSat = safeSeries(big_mat, 2, 6);
end

% -----------------------------------------------------------------------------
% buildSunDataFromOrbit  –  Build sunData from sun XYZ already in orbitData
%
% The sun position vectors are stored in big_mat row 9, columns 10-12 and are
% extracted by extractOrbitData into orbit.sunXYZ.  Using this source ensures
% the 3D scene lighting and the battery charging model are driven by exactly
% the same sun geometry — previously they could diverge when sun_xyz was loaded
% from an external variable that was independent of the simulation data.
%
% The raw ECI sun position is converted to a unit direction vector for use by
% the renderer and lighting system.
% -----------------------------------------------------------------------------
function sunData = buildSunDataFromOrbit(orbitData)
    % orbit.sunXYZ is [numSteps x 3] ECI sun position (km); normalise to unit dir
    sunData.available = true;
    sunData.xyz = normalizeVectorSeries(orbitData.sunXYZ, orbitData.numSteps, 'pchip');
end

% -----------------------------------------------------------------------------
% getSunDirection  –  Extract and validate a unit sun-direction vector
%
% Returns a safe fallback direction if the stored value is invalid.
% -----------------------------------------------------------------------------
function sunDir = getSunDirection(sunData, frameIdx)
    sunDir = unitVector(sunData.xyz(frameIdx, :));
    if ~all(isfinite(sunDir)) || norm(sunDir) <= eps
        sunDir = unitVector([1 0.25 0.65]);  % Fallback default direction
    end
end

% -----------------------------------------------------------------------------
% extractOrbitData  –  Unpack the geometry simulation (row 9) from big_mat
%
% Populates an orbit struct with:
%   satXYZ / velXYZ / gsXYZ  – position and velocity time-series
%   earthRadius               – planet radius in km (from channel 10)
%   altitude / inclination / minElevation – orbital parameters
%   uhfContact / sbandContact / anyContact – Boolean contact flags (rows 1 & 2)
%   elevation                 – computed line-of-sight elevation angle series
%   geometryContactMask       – true when elevation >= minElevation
%   numSteps / timeSec        – frame count and time axis
%   validFrameMask / firstFrame – which frames have finite XYZ data
%   sceneRadius / axisLimits  – 3D scene bounding box
%   tailLength                – number of trailing orbit points to draw
%   orbitalPeriodSec/Min      – estimated orbital period via vis-viva
% -----------------------------------------------------------------------------
function orbit = extractOrbitData(big_mat, timeSec)
    % Simulation 9 channel layout:
    %   1-3  = satellite XYZ (km, ECI)
    %   4-6  = satellite velocity XYZ (km/s, ECI)
    %   7-9  = ground station XYZ (km, ECI)
    %   10-12 = sun position XYZ (km, ECI) — used for lighting AND charging model
    %   13   = Earth radius (km)
    %   14   = altitude (km)
    %   15   = inclination (deg)
    %   16   = minimum contact elevation angle (deg)
    satXYZ = squeeze(big_mat(9, 1:3, :)).';
    velXYZ = squeeze(big_mat(9, 4:6, :)).';
    gsXYZ  = squeeze(big_mat(9, 7:9, :)).';
    sunXYZ = squeeze(big_mat(9, 10:12, :)).';

    orbit.satXYZ = satXYZ;
    orbit.velXYZ = fillMissingMatrix(velXYZ);  % Forward-fill NaN gaps
    orbit.gsXYZ  = fillMissingMatrix(gsXYZ);
    orbit.sunXYZ = fillMissingMatrix(sunXYZ);

    % Earth radius in km (channel 10); fall back to standard value if missing
    orbit.earthRadius = selectFiniteScalar(squeeze(big_mat(9, 13, :)), 6378);

    % Altitude: prefer channel 11; fall back to ||satXYZ|| - earthRadius
    derivedAltitude = vecnorm(satXYZ, 2, 2).' - orbit.earthRadius;
    orbit.altitude  = fillMissingVectorWithFallback(squeeze(big_mat(9, 14, :)).', derivedAltitude);

    % Inclination (degrees) and minimum contact elevation angle (degrees)
    orbit.inclination   = fillMissingVectorWithFallback(squeeze(big_mat(9, 15, :)).', zeros(1, size(big_mat, 3)));
    orbit.minElevation  = fillMissingVectorWithFallback(squeeze(big_mat(9, 16, :)).', 10 * ones(1, size(big_mat, 3)));

    % Contact flag time-series from the UHF (sim 1) and S-band (sim 2) rows
    orbit.uhfContact   = sanitizeBooleanLike(safeSeries(big_mat, 1, 9));
    orbit.sbandContact = sanitizeBooleanLike(safeSeries(big_mat, 2, 9));
    orbit.anyContact   = orbit.uhfContact | orbit.sbandContact;

    % Compute geometric elevation angle of the satellite above the horizon
    % at the ground station for each frame
    orbit.elevation           = computeElevationSeries(satXYZ, orbit.gsXYZ);
    orbit.geometryContactMask = orbit.elevation >= orbit.minElevation;

    orbit.numSteps = size(big_mat, 3);

    % Use the provided real-time vector directly (one timestamp per frame).
    % Normalise so that t=0 at the first sample regardless of absolute epoch.
    timeSec        = timeSec(:).';                      % ensure row vector
    orbit.timeSec  = timeSec - timeSec(1);              % elapsed seconds from start
    orbit.dt       = mean(diff(orbit.timeSec));         % mean step size (informational)

    % --- Cumulative contact time and contact count ---
    % Contact seconds are accumulated using the actual per-step dt (diff of
    % timeSec) rather than assuming uniform spacing.
    inContactMask = orbit.elevation >= 10;
    dtPerStep     = [diff(orbit.timeSec), mean(diff(orbit.timeSec))]; % [1 x numSteps]
    orbit.cumContactMin = cumsum(double(inContactMask) .* dtPerStep) / 60;

    % Count distinct contact passes: each rising edge (0→1) is one new contact
    edges = diff([0, inContactMask]);
    orbit.numContactsSeries = cumsum(double(edges > 0));  % [1 x numSteps]

    % --- Per-frame contact window limits (in hours, matching x-axis units) ---
    % For each frame, store the [start, end] time of the current contact window
    % (if in contact) or the next upcoming contact window (if not in contact).
    % Used by the communications plots to size the x-axis to exactly one window.
    timeHr = orbit.timeSec / 3600;
    nSteps = orbit.numSteps;
    risingEdges  = find(diff([0, inContactMask])  >  0);  % start of each window
    fallingEdges = find(diff([inContactMask, 0])  < 0);   % end of each window

    % Default: show full time range if no contact windows exist
    orbit.contactWindowXLim = repmat([timeHr(1), timeHr(end)], nSteps, 1);

    if ~isempty(risingEdges)
        for k = 1:numel(risingEdges)
            winStart = timeHr(risingEdges(k));
            winEnd   = timeHr(fallingEdges(k));
            % Assign this window to every frame from the start of this window
            % up to (but not including) the start of the next window.
            frameFrom = risingEdges(k);
            if k < numel(risingEdges)
                frameTo = risingEdges(k + 1) - 1;
            else
                frameTo = nSteps;
            end
            orbit.contactWindowXLim(frameFrom:frameTo, :) = ...
                repmat([winStart, winEnd], frameTo - frameFrom + 1, 1);
        end

        % Frames before the first contact window: show the first window
        if risingEdges(1) > 1
            orbit.contactWindowXLim(1:risingEdges(1)-1, :) = ...
                repmat([timeHr(risingEdges(1)), timeHr(fallingEdges(1))], ...
                        risingEdges(1)-1, 1);
        end
    end

    % A frame is "valid" only if all three satellite XYZ components are finite
    orbit.validFrameMask = all(isfinite(orbit.satXYZ), 2);
    orbit.firstFrame     = find(orbit.validFrameMask, 1, 'first');
    if isempty(orbit.firstFrame)
        error('Simulation 9 does not contain any valid satellite XYZ samples.');
    end

    % --- 3D scene bounding box ---
    satNorm    = vecnorm(orbit.satXYZ(orbit.validFrameMask, :), 2, 2);
    gsValidMask = all(isfinite(orbit.gsXYZ), 2);
    gsNorm     = vecnorm(orbit.gsXYZ(gsValidMask, :), 2, 2);
    allNorms   = [satNorm; gsNorm; orbit.earthRadius];

    orbit.sceneRadius  = 1.25 * max(allNorms);               % 25% margin around all objects
    orbit.axisLimits   = orbit.sceneRadius * [-1 1 -1 1 -1 1];  % Symmetric cubic bounding box
    orbit.tailLength   = min(80, max(25, round(orbit.numSteps / 20))); % Scales with dataset size

    % --- Orbital period estimate via Kepler's third law ---
    muEarth = 398600.4418;  % Earth's gravitational parameter (km^3/s^2)
    meanOrbitRadius    = orbit.earthRadius + meanFinite(orbit.altitude, 550);  % Average orbit radius (km)
    orbit.orbitalPeriodSec = 2 * pi * sqrt(meanOrbitRadius ^ 3 / muEarth);
    orbit.orbitalPeriodMin = orbit.orbitalPeriodSec / 60;
end

% -----------------------------------------------------------------------------
% buildSlides  –  Construct the 4-element array of slide specifications
%
% Each slide has:
%   title / subtitle        – display strings
%   showGroundRing          – whether the contact footprint ring is drawn
%   leftItems / rightItems  – arrays of item specs (timeseries, bar, text)
%
% opMode selects which simulation row is shown on the Power slide:
%   'Safe'    → sim row 3   'Nominal' → sim row 4   'Peak' → sim row 5
%
% Slides:
%   1 – Orbital Characteristics  (elevation plot + orbital metrics text)
%   2 – Power                    (battery level + charge rate time-series)
%   3 – Communications           (Eb/No, link loss, band status text)
%   4 – Computer Science         (packet buffer bar + software telemetry stub)
% -----------------------------------------------------------------------------
function slides = buildSlides(big_mat, orbit, opMode)
    numSteps = size(big_mat, 3);

    % Map operating mode string to the big_mat simulation row index.
    % Charge rate (genPower) is purely solar-geometry driven and is identical
    % across modes, so it always reads from sim row 3 regardless of opMode.
    switch upper(opMode)
        case 'SAFE'
            powerSimIdx = 3;
            modeColor   = [0.95 0.43 0.22];  % Orange
        case 'PEAK'
            powerSimIdx = 5;
            modeColor   = [0.99 0.82 0.18];  % Yellow
        otherwise  % 'NOMINAL' or unrecognised
            powerSimIdx = 4;
            modeColor   = [0.18 0.80 0.50];  % Green
    end

    % --- Slide 1: Orbital Characteristics ---
    slides(1).title        = 'Orbital Characteristics';
    slides(1).subtitle     = 'Elevation history with orbital summary metrics.';
    slides(1).showGroundRing = false;

    % Left column: elevation time-series (top) + orbital metrics text (bottom)
    orbMetricsItem = makeTextItem('Orbit Metrics', 'orbitalMetrics', 0.38, 9);
    orbMetricsItem.bodyFont = 'Courier New';
    slides(1).leftItems = [ ...
        makeTimeSeriesItem('Elevation vs Time', 'Elevation (deg)', numSteps, ...
            {orbit.elevation}, {'Elevation'}, [0.25 0.70 1.00], 0.62), ...
        orbMetricsItem];

    % Override default x-axis: convert to hours for readability, add reference line.
    % The data values are divided by 3600 so the axis label reads in hours while
    % the visual appearance (proportions, cursor position) is identical.
    slides(1).leftItems(1).xData   = orbit.timeSec / 3600;
    slides(1).leftItems(1).xLabel  = 'Time (hr)';
    slides(1).leftItems(1).referenceY     = 10;
    slides(1).leftItems(1).referenceLabel = 'e_{min} = 10 deg';

    % Right column:
    %   simConfigItem      — Simulation Configuration    (top,  weight 0.35)
    %   cumContactItem     — Cumulative Contact Time plot (mid,  weight 0.40)
    %   contactInfoItem    — Data sent + clock + count    (bot,  weight 0.25)
    simConfigItem = makeTextItem('Simulation Configuration', 'simConfig', 0.35, 9);
    simConfigItem.bodyFont = 'Courier New';

    cumContactItem = makeTimeSeriesItem( ...
        'Cumulative Contact Time (min)', 'Contact Time (min)', numSteps, ...
        {orbit.cumContactMin}, {'Contact time'}, [0.25 0.80 1.00], 0.40);
    cumContactItem.xData      = orbit.timeSec / 3600;
    cumContactItem.xLabel     = 'Mission Time (hr)';
    cumContactItem.showLegend = false;

    % Data sent, mission clock and contact count combined into one text card —
    % no individual titles, all rendered as a single block like the power card.
    contactInfoItem = makeTextItem('Contact Information', 'contactInfo', 0.25, 9);
    contactInfoItem.bodyFont = 'Courier New';

    slides(1).rightItems = [simConfigItem, cumContactItem, contactInfoItem];

    % --- Slide 2: Power ---
    slides(2).title        = 'Power';
    slides(2).subtitle     = sprintf('Battery telemetry — %s mode.', opMode);
    slides(2).showGroundRing = false;

    % Left: battery level for the active operating mode only (single series).
    % X-axis uses sample index; update xLabel below if time data is preferred.
    batteryItem = makeTimeSeriesItem( ...
        sprintf('Battery Level (%s)', opMode), 'Battery Level (W·h)', numSteps, ...
        {safeSeries(big_mat, powerSimIdx, 1)}, ...
        {opMode}, modeColor, 0.58);
    % Window width = one third of total simulation duration in hours.
    powerWindowSize = (orbit.timeSec(end) - orbit.timeSec(1)) / 3 / 3600;

    batteryItem.xLabel      = 'Time (hr)';
    batteryItem.xData       = orbit.timeSec / 3600;
    batteryItem.xWindowSize = powerWindowSize;

    % The static text shown in the lower-left card on the Power slide is
    % defined in the 'powerStub' case of buildTextBody() near the bottom of
    % this file.  Edit the sprintf string there to change what it displays.
    % Courier New is used so the load value columns line up correctly.
    powerTextItem = makeTextItem('Battery / Mode Stub', 'powerStub', 0.42, 9);
    powerTextItem.bodyFont = 'Courier New';
    slides(2).leftItems = [ ...
        batteryItem, ...
        powerTextItem];

    % Right: generated power (green) vs total load for the active mode (red).
    % genPower is solar-geometry driven and comes from sim row 3, param 2.
    % Load comes from sim rows 3-5, param 3 (safe/nominal/peak respectively),
    % selected by powerSimIdx which is already resolved from opMode above.
    chargeItem = makeTimeSeriesItem('Power (W)', 'Power (W)', numSteps, ...
        {safeSeries(big_mat, 3, 2), safeSeries(big_mat, powerSimIdx, 3)}, ...
        {'genPower', 'Load'}, ...
        [0.18 0.80 0.30; 0.90 0.25 0.20], 0.58);
    chargeItem.xLabel      = 'Time (hr)';
    chargeItem.xData       = orbit.timeSec / 3600;
    chargeItem.xWindowSize = powerWindowSize;
    % Bottom-right: thermal information card — Courier New for column alignment.
    % Static irradiance constants plus dynamic thermal power and mass per mode.
    thermalTextItem = makeTextItem('Thermal Information', 'thermalInfo', 0.42, 9);
    thermalTextItem.bodyFont = 'Courier New';
    slides(2).rightItems = [ ...
        chargeItem, ...
        thermalTextItem];

    % --- Slide 3: Communications ---
    slides(3).title        = 'Communications';
    slides(3).subtitle     = 'Active link view with 10 degree ground-station mask ring.';
    slides(3).showGroundRing = true;  % Show contact footprint ring in 3D scene

    % Left: wireless comms status text + Eb/No time-series
    ebnoItem = makeCommItem('commEbNo', 'Eb/No', 'Eb/No (dB)', numSteps, ...
        [0.26 0.63 1.00; 1.00 0.59 0.18], 0.68);
    ebnoItem.xLabel       = 'Time (hr)';
    ebnoItem.xData        = orbit.timeSec / 3600;
    ebnoItem.xWindowMode  = 'contact';
    ebnoItem.fixedYLimits = true;
    ebnoItem.referenceY     = 7.8;
    ebnoItem.referenceLabel = 'Min required Eb/No';
    wirelessCommItem = makeTextItem('Wireless Communications', 'wirelessComm', 0.32, 9);
    wirelessCommItem.bodyFont = 'Courier New';
    slides(3).leftItems = [ ...
        wirelessCommItem, ...
        ebnoItem];

    % Right: link loss — solid magenta (downlink) and dotted magenta (uplink)
    magenta  = [0.90 0.10 0.90];
    lossItem = makeCommItem('commLoss', 'Link Loss', 'Path Loss (dB)', numSteps, ...
        [magenta; magenta], 0.60);
    lossItem.lineStyles   = {'-', ':'};
    lossItem.xLabel       = 'Time (hr)';
    lossItem.xData        = orbit.timeSec / 3600;
    lossItem.xWindowMode  = 'contact';
    lossItem.fixedYLimits = true;
    simBackendItem = makeTextItem('Simulation back end', 'simBackend', 0.40, 9);
    simBackendItem.bodyFont = 'Courier New';
    slides(3).rightItems = [ ...
        lossItem, ...
        simBackendItem];

    % --- Slide 4: Computer Science ---
    slides(4).title        = 'Computer Science';
    slides(4).subtitle     = 'Buffer visualization with software telemetry.';
    slides(4).showGroundRing = true;

    % Left: packet buffer bar (max 128) + telemetry text card below
    csTelemetryItem = makeTextItem('Telemetry', 'csTelemetry', 0.45, 9);
    csTelemetryItem.bodyFont = 'Courier New';
    slides(4).leftItems = [ ...
        makeBarItem('Packet Buffer', 'Queued Packets', 'Buffer', [0 128], [0.32 0.72 1.00], 0.55), ...
        csTelemetryItem];

    % Right: mode management text card + software information below
    modeManagementItem = makeTextItem('Mode Management', 'modeManagement', 0.55, 9);
    modeManagementItem.bodyFont = 'Courier New';
    swInfoItem = makeTextItem('Software Information', 'swInfo', 0.45, 9);
    swInfoItem.bodyFont = 'Courier New';
    slides(4).rightItems = [ ...
        modeManagementItem, ...
        swInfoItem];
end

% -----------------------------------------------------------------------------
% makeTimeSeriesItem  –  Factory: build a spec struct for a time-series plot
% -----------------------------------------------------------------------------
function spec = makeTimeSeriesItem(titleText, yLabel, timeCount, seriesCell, legendLabels, colors, heightWeight)
    spec = emptyItemSpec();
    spec.kind         = 'timeseries';
    spec.title        = titleText;
    spec.yLabel       = yLabel;
    spec.timeCount    = timeCount;
    spec.seriesCell   = seriesCell;    % Cell array of data vectors (one per line)
    spec.legendLabels = legendLabels;
    spec.colors       = colors;        % [nLines x 3] RGB array
    spec.xData        = 1:timeCount;   % Default x-axis: sample index
    spec.xLabel       = 'Sample';
    spec.heightWeight = heightWeight;
end

% -----------------------------------------------------------------------------
% makeCommItem  –  Factory: build a spec for a communications time-series
%
% Like makeTimeSeriesItem but with a fixed 'Downlink'/'Uplink' legend
% and a kind of 'commEbNo' or 'commLoss' so the active band can be chosen
% dynamically at render time.
% -----------------------------------------------------------------------------
function spec = makeCommItem(kindValue, titleText, yLabel, timeCount, colors, heightWeight)
    spec = emptyItemSpec();
    spec.kind         = kindValue;
    spec.title        = titleText;
    spec.yLabel       = yLabel;
    spec.timeCount    = timeCount;
    spec.legendLabels = {'Downlink', 'Uplink'};
    spec.colors       = colors;
    spec.xData        = 1:timeCount;
    spec.xLabel       = 'Sample';
    spec.heightWeight = heightWeight;
end

% -----------------------------------------------------------------------------
% makeTextItem  –  Factory: build a spec for a dynamic text card
%
% textRole is a string key used by buildTextBody() to generate the content.
% -----------------------------------------------------------------------------
function spec = makeTextItem(titleText, textRole, heightWeight, bodyFontSize)
    spec = emptyItemSpec();
    spec.kind        = 'text';
    spec.title       = titleText;
    spec.textRole    = textRole;
    spec.heightWeight = heightWeight;
    spec.bodyFontSize = bodyFontSize;
end

% -----------------------------------------------------------------------------
% makePlaceholderItem  –  Factory: build a spec for a static placeholder card
%
% Displays a fixed stub message; used where future plots/text will be added.
% -----------------------------------------------------------------------------
function spec = makePlaceholderItem(titleText, staticText, heightWeight)
    spec = emptyItemSpec();
    spec.kind        = 'placeholder';
    spec.title       = titleText;
    spec.textRole    = 'staticPlaceholder';
    spec.staticText  = staticText;
    spec.heightWeight = heightWeight;
    spec.bodyFontSize = 10;
end

% -----------------------------------------------------------------------------
% makeBarItem  –  Factory: build a spec for a vertical bar chart
% -----------------------------------------------------------------------------
function spec = makeBarItem(titleText, yLabel, xLabel, yLimits, barColor, heightWeight)
    spec = emptyItemSpec();
    spec.kind        = 'bar';
    spec.title       = titleText;
    spec.yLabel      = yLabel;
    spec.xLabel      = xLabel;
    spec.yLimits     = yLimits;
    spec.barColor    = barColor;
    spec.heightWeight = heightWeight;
end

% -----------------------------------------------------------------------------
% emptyItemSpec  –  Return a default item spec struct with all fields present
%
% Every makeXxxItem factory starts from this so struct arrays are homogeneous.
% -----------------------------------------------------------------------------
function spec = emptyItemSpec()
    spec = struct( ...
        'kind',         '', ...
        'title',        '', ...
        'yLabel',       '', ...
        'timeCount',    [], ...
        'seriesCell',   {{}}, ...
        'legendLabels', {{}}, ...
        'colors',       zeros(0, 3), ...
        'heightWeight', 1, ...
        'textRole',     '', ...
        'staticText',   '', ...
        'xLabel',       '', ...
        'xData',        [], ...
        'yLimits',      [], ...
        'barColor',     [0.5 0.5 0.5], ...
        'referenceY',   [], ...
        'referenceLabel', '', ...
        'bodyFontSize', 10, ...
        'bodyFont',     'Helvetica', ...  % Use 'Courier New' for monospaced alignment
        'showLegend',   true, ...         % Set to false to suppress the legend box
        'xWindowSize',  0, ...            % Paged x-axis window width; 0 = show full range
        'fixedYLimits', false, ...        % true = freeze y-axis at init limits, no per-frame rescale
        'lineStyles',   {{}}, ...         % Cell array of line style strings, e.g. {'-','--',':'}
        'xWindowMode',  'paged');         % 'paged' = fixed-width pages; 'contact' = size to contact window
end

% -----------------------------------------------------------------------------
% queryExternalControlStateStub  –  Stub for future external pipe reader
%QUERYEXTERNALCONTROLSTATESTUB Replace this with a pipe reader later.
%   Future integration point:
%   1. Read mode/frequency/packet values from the C pipe.
%   2. Populate the fields below.
%   3. Keep the plotting code unchanged.
%
% Currently infers the active band from the contact flags (or honours an
% explicit override from stubCommSelection) and derives contact state
% from the orbit data.
% -----------------------------------------------------------------------------
function controlState = queryExternalControlStateStub(frameIdx, orbit, controlConfig)
    % Active band: use the live value written by the main loop from s.freq.
    % Falls back to stubCommSelection if liveActiveBand is not yet set.
    if isfield(controlConfig, 'liveActiveBand') && ~isempty(controlConfig.liveActiveBand)
        activeBand = upper(controlConfig.liveActiveBand);
    else
        requestedBand = upper(controlConfig.stubCommSelection{frameIdx});
        autoBand      = inferActiveBand(frameIdx, orbit);
        switch requestedBand
            case 'UHF',                          activeBand = 'UHF';
            case {'S-BAND','SBAND','S_BAND'},     activeBand = 'S-BAND';
            otherwise,                           activeBand = autoBand;
        end
    end

    % Packet count: live value from s.count (falls back to static series)
    if isfield(controlConfig, 'livePacketCount')
        packetCount = controlConfig.livePacketCount;
    else
        packetCount = controlConfig.packetCount(frameIdx);
    end

    % Task string: live value from s.tasks
    if isfield(controlConfig, 'liveTasks')
        pipeTasks = controlConfig.liveTasks;
    else
        pipeTasks = '';
    end

    controlState.activeBand  = activeBand;
    controlState.modeLabel   = controlConfig.stubModeLabel{frameIdx};
    controlState.packetCount = packetCount;
    controlState.opMode      = controlConfig.opMode;
    controlState.pipeTasks   = pipeTasks;

    % Per-frame values needed by the power slide dynamic load lines
    controlState.genPower  = controlConfig.genPower(frameIdx);
    controlState.elevation = orbit.elevation(frameIdx);

    % Thermal constants (mode-independent, scalar)
    controlState.thermalMaxIrradiance = controlConfig.thermalMaxIrradiance;
    controlState.thermalMinIrradiance = controlConfig.thermalMinIrradiance;
    controlState.thermalAvgIrradiance = controlConfig.thermalAvgIrradiance;

    % Per-frame thermal power and mass — select the series for the active mode
    switch upper(controlConfig.opMode)
        case 'SAFE'
            controlState.thermalPower       = controlConfig.thermalPowerSafe(frameIdx);
            controlState.massWithoutPayload = controlConfig.massWithoutPayloadSafe(frameIdx);
            controlState.massWithPayload    = controlConfig.massWithPayloadSafe(frameIdx);
        case 'PEAK'
            controlState.thermalPower       = controlConfig.thermalPowerPeak(frameIdx);
            controlState.massWithoutPayload = controlConfig.massWithoutPayloadPeak(frameIdx);
            controlState.massWithPayload    = controlConfig.massWithPayloadPeak(frameIdx);
        otherwise  % NOMINAL
            controlState.thermalPower       = controlConfig.thermalPowerNominal(frameIdx);
            controlState.massWithoutPayload = controlConfig.massWithoutPayloadNominal(frameIdx);
            controlState.massWithPayload    = controlConfig.massWithPayloadNominal(frameIdx);
    end

    % Determine whether the satellite is in contact via the selected band
    controlState.isInContact = inferContactState(activeBand, frameIdx, orbit);

    % Wireless comm values for the active band at this frame
    if strcmpi(activeBand, 'S-BAND')
        controlState.cnUplink    = controlConfig.sbandCNUplink(frameIdx);
        controlState.cnDownlink  = controlConfig.sbandCNDownlink(frameIdx);
        controlState.rxPowerGS   = controlConfig.sbandRxPowerGS(frameIdx);
        controlState.rxPowerSat  = controlConfig.sbandRxPowerSat(frameIdx);
        controlState.dataRateBps = 96000;
        controlState.dataRateStr = '96,000';
    else  % UHF or NO LINK — fall back to UHF values
        controlState.cnUplink    = controlConfig.uhfCNUplink(frameIdx);
        controlState.cnDownlink  = controlConfig.uhfCNDownlink(frameIdx);
        controlState.rxPowerGS   = controlConfig.uhfRxPowerGS(frameIdx);
        controlState.rxPowerSat  = controlConfig.uhfRxPowerSat(frameIdx);
        controlState.dataRateBps = 19200;
        controlState.dataRateStr = '19,200';
    end
end

% -----------------------------------------------------------------------------
% inferActiveBand  –  Determine the best available band from contact flags
%
% Priority: S-band > UHF > no link.
% -----------------------------------------------------------------------------
function bandLabel = inferActiveBand(frameIdx, orbit)
    if orbit.sbandContact(frameIdx)
        bandLabel = 'S-BAND';
    elseif orbit.uhfContact(frameIdx)
        bandLabel = 'UHF';
    else
        bandLabel = 'NO LINK';
    end
end

% -----------------------------------------------------------------------------
% inferContactState  –  Check whether contact is established on a given band
%
% For 'AUTO' / unknown band, accepts contact from either band or from the
% geometric elevation mask.
% -----------------------------------------------------------------------------
function tf = inferContactState(activeBand, frameIdx, orbit)
    switch upper(activeBand)
        case 'S-BAND'
            tf = orbit.sbandContact(frameIdx);
        case 'UHF'
            tf = orbit.uhfContact(frameIdx);
        otherwise
            % Accept any available contact when band is not explicitly selected
            tf = orbit.anyContact(frameIdx) | orbit.geometryContactMask(frameIdx);
    end
end

% -----------------------------------------------------------------------------
% resolveTimeSeriesContent  –  Return the data cell array and title for a
%   standard time-series item (data is static; title does not change)
% -----------------------------------------------------------------------------
function [seriesCell, titleText] = resolveTimeSeriesContent(spec, ~, ~)
    seriesCell = spec.seriesCell;
    titleText  = spec.title;
end

% -----------------------------------------------------------------------------
% resolveCommSeries  –  Select the Eb/No or link-loss series for the active band
%
% The active band determines which simulation row to read (1 = UHF, 2 = S-band).
% Values are set to NaN at all frames where that band is not in contact so the
% plot shows gaps rather than meaningless out-of-contact data.
% Parameters: ebno uses columns 1 & 2; loss uses columns 7 & 8.
% -----------------------------------------------------------------------------
function [seriesCell, titleText] = resolveCommSeries(spec, controlState, metricKind)
    big_mat = getRuntimeBigMat();

    % Map active band to simulation row index and its contact mask
    switch upper(controlState.activeBand)
        case 'S-BAND'
            simIdx      = 2;
            contactMask = sanitizeBooleanLike(safeSeries(big_mat, 2, 9));
        otherwise  % UHF or NO LINK
            simIdx      = 1;
            contactMask = sanitizeBooleanLike(safeSeries(big_mat, 1, 9));
    end

    switch metricKind
        case 'ebno'
            seriesCell = {maskedSeries(simIdx, 1), maskedSeries(simIdx, 2)};
            titleText  = spec.title;
        case 'loss'
            seriesCell = {maskedSeries(simIdx, 7), maskedSeries(simIdx, 8)};
            titleText  = spec.title;
        otherwise
            error('Unsupported communications metric kind: %s', metricKind);
    end

    % Return a series with NaN wherever the band is not in contact
    function values = maskedSeries(simIndex, paramIndex)
        values = safeSeries(big_mat, simIndex, paramIndex);
        values(~contactMask) = NaN;
    end
end

% -----------------------------------------------------------------------------
% resolveBarValue  –  Determine the scalar value for a bar chart at this frame
%
% Currently only 'Packet Buffer' is handled; other bar titles return 0.
% -----------------------------------------------------------------------------
function value = resolveBarValue(spec, ~, controlState)
    switch spec.title
        case 'Packet Buffer'
            value = controlState.packetCount;
        otherwise
            value = 0;
    end

    % Guard against NaN/Inf and enforce the lower y-limit floor
    if ~isfinite(value)
        value = 0;
    end
    value = max(spec.yLimits(1), value);
end

% -----------------------------------------------------------------------------
% buildTextBody  –  Generate the multi-line body string for a text card
%
% Dispatches on textRole to format the appropriate telemetry fields.
% -----------------------------------------------------------------------------
function bodyText = buildTextBody(textRole, frameIdx, controlState, orbit)
    switch textRole
        case 'orbitalMetrics'
            % Velocity magnitude from the 3-component velocity vector (km/s)
            velVec  = orbit.velXYZ(frameIdx, :);
            velMag  = norm(velVec);

            bodyText = sprintf(['Elevation    = %.1f deg\n'  ...
                                'Altitude     = %.1f km\n'   ...
                                'Inclination  = %.1f deg\n'  ...
                                'Period       = %.1f min\n'  ...
                                'Velocity     = %.3f km/s\n' ...
                                '\n'                         ...
                                'Debris flux:\n'             ...
                                '  10 \xB5m  = 15,800 m\xB2/yr\n' ...
                                '  100 \xB5m = 95.7 m\xB2/yr'], ...
                                orbit.elevation(frameIdx),  ...
                                orbit.altitude(frameIdx),   ...
                                orbit.inclination(frameIdx),...
                                orbit.orbitalPeriodMin,     ...
                                velMag);
        case 'orbitalGeometry'
            % Ground link state and per-band contact flags
            bodyText = sprintf(['Ground link state: %s\n' ...
                                'Min elevation: %.1f deg\n' ...
                                'UHF contact: %s\n' ...
                                'S-band contact: %s'], ...
                                logicalText(controlState.isInContact), ...
                                orbit.minElevation(frameIdx), ...
                                logicalText(orbit.uhfContact(frameIdx)), ...
                                logicalText(orbit.sbandContact(frameIdx)));

        case 'contactInfo'
            % Combined data sent + mission clock + contact count block.
            % Data rate comes from controlState (set by active band in queryExternalControlStateStub).
            rateStr = [controlState.dataRateStr, ' bps'];

            % cumContactMin is in minutes; convert back to seconds for data calc
            totalContactSec = orbit.cumContactMin(frameIdx) * 60;
            totalBytes = totalContactSec * controlState.dataRateBps / 8;
            if totalBytes >= 1e6
                dataStr = sprintf('%.2f MB', totalBytes / 1e6);
            elseif totalBytes >= 1e3
                dataStr = sprintf('%.2f kB', totalBytes / 1e3);
            else
                dataStr = sprintf('%.0f B', totalBytes);
            end

            % Mission clock from real elapsed time — round to nearest second
            % to prevent floating-point residuals producing e+N notation.
            totalSec = round(orbit.timeSec(frameIdx));
            hh = floor(totalSec / 3600);
            mm = floor(mod(totalSec, 3600) / 60);
            ss = mod(totalSec, 60);

            bodyText = sprintf(['Data sent    = %s (@ %s)\n' ...
                                'Mission time = %02d:%02d:%02d\n' ...
                                'Contacts     = %d'], ...
                                dataStr, rateStr, hh, mm, ss, ...
                                orbit.numContactsSeries(frameIdx));

        case 'simConfig'
            % ----------------------------------------------------------------
            % SIMULATION CONFIGURATION CARD
            % Constants are hardcoded here. The operating mode and selected
            % frequency update dynamically from controlState each frame.
            % ----------------------------------------------------------------
            bodyText = sprintf(['Op mode           = %s\n' ...
                                'Frequency         = %s\n' ...
                                'Satellite version = OKSat-S26-b\n' ...
                                'Sim version       = 1.2.1\n' ...
                                '\n' ...
                                'Current simulations:\n' ...
                                '  Orbital Geometry\n' ...
                                '  Power\n' ...
                                '  Wireless Comms\n' ...
                                '  Digital Comms'], ...
                                controlState.opMode, ...
                                controlState.activeBand);
        case 'thermalInfo'
            % ----------------------------------------------------------------
            % THERMAL INFORMATION CARD
            % Static irradiance rows come from big_mat(6, 1:3, 1) — constant.
            % Dynamic values (thermal power, mass) update each frame and are
            % mode-dependent (rows 6/7/8 = safe/nominal/peak).
            % ----------------------------------------------------------------

            % Static irradiance constants (same for all modes and all frames)
            irradianceText = sprintf(['Max Irradiance     = %.2f W/m^2\n' ...
                                      'Min Irradiance     = %.2f W/m^2\n' ...
                                      'Avg Irradiance     = %.2f W/m^2'], ...
                                      controlState.thermalMaxIrradiance, ...
                                      controlState.thermalMinIrradiance, ...
                                      controlState.thermalAvgIrradiance);

            % Dynamic thermal power — updates each frame, mode-dependent
            switch upper(controlState.opMode)
                case 'SAFE'
                    thermalLabel = 'Thermal pwr (Safe)';
                case 'PEAK'
                    thermalLabel = 'Thermal pwr (Peak)';
                otherwise
                    thermalLabel = 'Thermal pwr (Nom) ';
            end
            dynamicText = sprintf(['\n%s = %.2f W/m^2\n' ...
                                   'Mass (w/o payload) = %.3f kg\n' ...
                                   'Mass (w/  payload) = %.3f kg'], ...
                                   thermalLabel, controlState.thermalPower, ...
                                   controlState.massWithoutPayload, ...
                                   controlState.massWithPayload);

            bodyText = [irradianceText, dynamicText];

        case 'powerStub'
            % ----------------------------------------------------------------
            % POWER SLIDE STATIC TEXT
            % Edit the load values in the switch block below to update what
            % appears in the "Battery / Mode Stub" card on the Power slide.
            %
            % Static loads (fixed per mode) are defined in the switch.
            % Dynamic loads update every frame based on live telemetry:
            %   AX100-TX  = 2.64 W when elevation >= 10 deg, else 0 W
            %   BPX heater = 6 W when genPower = 0 (eclipse), else 0 W
            % ----------------------------------------------------------------

            % --- Dynamic loads (update each frame) ---
            if controlState.elevation >= 10
                txLoad = 2.64;
            else
                txLoad = 0;
            end

            if controlState.genPower <= 0
                heaterLoad = 6.0;
            else
                heaterLoad = 0;
            end

            % --- Static header (same for all modes) ---
            % Column ruler: "Label............" = value
            headerText = sprintf(['Mode: %s\n' ...
                                  'Battery Capacity   = 100 Wh\n' ...
                                  'Max power gen      = 42 W\n' ...
                                  'Max gen (Earth-pt) = 24 W'], ...
                                  controlState.modeLabel);

            % --- Per-mode static load breakdown ---
            switch upper(controlState.opMode)
                case 'SAFE'
                    loadText = sprintf(['\nTotal load         = 2.24 W\n' ...
                                        '  OBC load         = 0.1485 W\n' ...
                                        '  P60 housekeep    = 1.005 W\n' ...
                                        '  AX100-RX load    = 0.182 W\n' ...
                                        '  iADCS avg load   = 0.9 W\n']);
                case 'PEAK'
                    loadText = sprintf(['\nTotal load         = 9.14 W\n' ...
                                        '  OBC load         = 0.1485 W\n' ...
                                        '  P60 housekeep    = 1.005 W\n' ...
                                        '  AX100-RX load    = 0.182 W\n' ...
                                        '  iADCS peak load  = 5.0 W\n' ...
                                        '  Payload          = 2.8 W\n' ...
                                        '  (SONY IMX327)\n']);
                otherwise  % NOMINAL
                    loadText = sprintf(['\nTotal load         = 6.14 W\n' ...
                                        '  OBC load         = 0.1485 W\n' ...
                                        '  P60 housekeep    = 1.005 W\n' ...
                                        '  AX100-RX load    = 0.182 W\n' ...
                                        '  iADCS avg load   = 2.0 W\n' ...
                                        '  Payload          = 2.8 W\n' ...
                                        '  (SONY IMX327)\n']);
            end

            % --- Dynamic loads (update each frame) ---
            dynamicText = sprintf(['  AX100-TX load    = %.2f W%s\n' ...
                                   '  BPX heater load  = %.2f W%s'], ...
                                   txLoad,     ternary(txLoad > 0,     ' (in contact)', ' (no contact)'), ...
                                   heaterLoad, ternary(heaterLoad > 0, ' (eclipse)',    ''));

            bodyText = [headerText, loadText, dynamicText];
        case 'wirelessComm'
            % ----------------------------------------------------------------
            % WIRELESS COMMUNICATIONS CARD
            % C/N and received power are shown as N/A when not in contact and
            % resume the real simulation values when contact is established.
            % ----------------------------------------------------------------
            if controlState.isInContact
                bodyText = sprintf(['Band             = %s\n'        ...
                                    'Data rate        = %s bps\n'    ...
                                    'Num contacts     = %d\n'        ...
                                    '\n'                             ...
                                    'C/N uplink       = %.2f dB\n'  ...
                                    'C/N downlink     = %.2f dB\n'  ...
                                    '\n'                             ...
                                    'Rx power (GS)    = %.2f dBW\n' ...
                                    'Rx power (sat)   = %.2f dBW'], ...
                                    controlState.activeBand,         ...
                                    controlState.dataRateStr,        ...
                                    orbit.numContactsSeries(frameIdx), ...
                                    controlState.cnUplink,           ...
                                    controlState.cnDownlink,         ...
                                    controlState.rxPowerGS,          ...
                                    controlState.rxPowerSat);
            else
                bodyText = sprintf(['Band             = %s\n'     ...
                                    'Data rate        = %s bps\n' ...
                                    'Num contacts     = %d\n'     ...
                                    '\n'                          ...
                                    'C/N uplink       = N/A\n'   ...
                                    'C/N downlink     = N/A\n'   ...
                                    '\n'                          ...
                                    'Rx power (GS)    = N/A\n'   ...
                                    'Rx power (sat)   = N/A'],   ...
                                    controlState.activeBand,      ...
                                    controlState.dataRateStr,     ...
                                    orbit.numContactsSeries(frameIdx));
            end
        case 'csStub'
            % Computer science / software telemetry stub (legacy — kept for reference)
            bodyText = sprintf(['Packet buffer count: %.0f\n' ...
                                'Mode input: %s\n' ...
                                'Ground contact: %s\n\n' ...
                                'TODO:\n' ...
                                '- hook software telemetry pipe\n' ...
                                '- add scheduler / queue status'], ...
                                controlState.packetCount, ...
                                controlState.modeLabel, ...
                                logicalText(controlState.isInContact));

        case 'csTelemetry'
            % ----------------------------------------------------------------
            % TELEMETRY CARD
            % Shows contact boolean and packet buffer fill out of 128.
            % ----------------------------------------------------------------
            if controlState.isInContact
                contactStr = 'true';
            else
                contactStr = 'false';
            end
            bodyText = sprintf(['In contact  = %s\n' ...
                                'Buffer      = %.0f / 128'], ...
                                contactStr, ...
                                controlState.packetCount);

        case 'modeManagement'
            % ----------------------------------------------------------------
            % MODE MANAGEMENT CARD
            % Op mode is mapped from s.mode (2=Nominal, 3=Peak, 4=Safe).
            % Active task list is parsed from controlState.pipeTasks, which
            % is the raw string received from s.tasks via the C pipe.
            % Expected format: comma-separated task names, e.g.
            %   "Downlink TX, Buffer flush, ADCS control"
            % An empty string or whitespace-only string shows "(none)".
            % ----------------------------------------------------------------

            % Parse pipe task string into individual task names
            rawTasks = strtrim(controlState.pipeTasks);
            if isempty(rawTasks)
                parsedTasks = {};
            else
                parts = strsplit(rawTasks, ',');
                parsedTasks = strtrim(parts);
                % Remove any empty tokens produced by trailing commas
                parsedTasks = parsedTasks(~cellfun('isempty', parsedTasks));
            end

            % Build task list display lines
            if isempty(parsedTasks)
                taskLines = 'Active tasks: (none)';
            else
                taskLines = 'Active tasks:';
                for tIdx = 1:numel(parsedTasks)
                    taskLines = [taskLines, sprintf('\n  [%d] %s', tIdx, parsedTasks{tIdx})]; %#ok<AGROW>
                end
            end

            bodyText = sprintf('Op mode     = %s\n\n%s', ...
                                controlState.opMode, taskLines);
        case 'swInfo'
            % ----------------------------------------------------------------
            % SOFTWARE INFORMATION CARD
            % Static fields describing the onboard software and simulation
            % environment. Update these strings if the configuration changes.
            % ----------------------------------------------------------------
            bodyText = sprintf(['Operating System  = FreeRTOS\n' ...
                                'Backend Sim       = POSIX\n'    ...
                                'Onboard Computer  = NanoMind A3200']);

        case 'simBackend'
            % ----------------------------------------------------------------
            % SIMULATION BACK END CARD
            % Static reference list of propagation models and standards used
            % in the wireless communications simulation back end.
            % ----------------------------------------------------------------
            bodyText = sprintf(['Propagation losses: ITU-R P.618\n'          ...
                                'Similar cubesat missions\n'                 ...
                                'Cross-polarization: ITU-R P.618\n'          ...
                                'Sky Noise: ITU-R P.618,\n'                  ...
                                '  Ippolito 2017\n'                          ...
                                '\n'                                         ...
                                'Ionospheric scintillation:\n'               ...
                                '  ITU-R P.531, GISM, WBMod 17\n'            ...
                                '\n'                                         ...
                                'TEC: NeQuick2\n'                            ...
                                'Antenna Gains: Data-sheet Interpolation\n'  ...
                                'Polarization loss:\n'                       ...
                                '  3dB (UHF)\n'                              ...
                                '  Calculated from geometry\n'               ...
                                '  (S-band)']);
        case 'staticPlaceholder'
            % Placeholder cards have no dynamic body content
            bodyText = '';
        otherwise
            bodyText = sprintf('TODO: define text role "%s".', textRole);
    end
end

% -----------------------------------------------------------------------------
% composeCenterInfo  –  Format the telemetry text overlay for the 3D scene
% -----------------------------------------------------------------------------
function txt = composeCenterInfo(orbit, frameIdx, controlState)
    txt = sprintf(['Altitude: %.1f km\n' ...
                   'Elevation: %.1f deg\n' ...
                   'Inclination: %.1f deg\n' ...
                   'Active band: %s'], ...
                   orbit.altitude(frameIdx), ...
                   orbit.elevation(frameIdx), ...
                   orbit.inclination(frameIdx), ...
                   controlState.activeBand);
end

% -----------------------------------------------------------------------------
% buildGroundStationRing  –  Compute a circle on Earth's surface representing
%   the minimum-elevation contact footprint of the ground station
%
% The ring is the locus of points on Earth's surface from which the satellite
% is visible above elevationDeg degrees.  The angular radius (psi) is found
% by solving the geometry equation numerically.
% -----------------------------------------------------------------------------
function ringXYZ = buildGroundStationRing(gsPoint, earthRadius, altitudeKm, elevationDeg)
    gsUnit = unitVector(gsPoint);

    % Return a NaN ring if the ground station position is invalid
    if ~all(isfinite(gsUnit))
        ringXYZ = nan(180, 3);
        return;
    end

    altValue = max(1, altitudeKm);  % Ensure positive altitude

    % Solve for the half-angle (psi) of the contact footprint cone
    psi = solveGroundMaskAngle(earthRadius, earthRadius + altValue, elevationDeg);

    % Build an orthonormal pair of vectors perpendicular to gsUnit for the ring plane
    [basis1, basis2] = buildPerpendicularBasis(gsUnit);

    % Parametric circle at angular radius psi centred on the ground station
    theta   = linspace(0, 2 * pi, 180).';
    ringXYZ = earthRadius * ( ...
        cos(psi) * gsUnit + ...
        sin(psi) * (cos(theta) * basis1 + sin(theta) * basis2));
end

% -----------------------------------------------------------------------------
% solveGroundMaskAngle  –  Find the Earth central angle for an elevation mask
%
% Solves for the ground-track half-angle psi such that a satellite at
% orbitRadius has an elevation of elevationDeg above the horizon at a ground
% point that is psi radians from the sub-satellite point.
%
% The equation is:  atan2(cos(psi) - rho, sin(psi)) = elevRad
% where rho = earthRadius / orbitRadius.
% -----------------------------------------------------------------------------
function psi = solveGroundMaskAngle(earthRadius, orbitRadius, elevationDeg)
    rho     = earthRadius / orbitRadius;  % Ratio of radii
    elevRad = deg2rad(elevationDeg);

    % Maximum possible psi is where the orbit is at the horizon (elevation = 0)
    maxPsi  = acos(max(-1, min(1, rho)));

    % Solve numerically for the exact psi that matches the requested elevation
    objective = @(x) atan2(cos(x) - rho, sin(x)) - elevRad;
    psi = fzero(objective, [0, maxPsi]);
end

% -----------------------------------------------------------------------------
% buildPerpendicularBasis  –  Compute two unit vectors orthogonal to vec
%
% Uses Gram-Schmidt. Avoids near-parallel reference by switching from [0,0,1]
% to [0,1,0] when vec is nearly aligned with the z-axis.
% -----------------------------------------------------------------------------
function [basis1, basis2] = buildPerpendicularBasis(vec)
    ref = [0 0 1];
    if abs(dot(vec, ref)) > 0.95
        ref = [0 1 0];  % Fall back to y-axis when vec is nearly vertical
    end
    basis1 = unitVector(cross(vec, ref));
    basis2 = unitVector(cross(vec, basis1));
end

% -----------------------------------------------------------------------------
% getSeriesCount  –  Return the number of data lines for a given item spec
%
% Time-series items carry an explicit cell array; comm items always have 2
% (downlink + uplink).
% -----------------------------------------------------------------------------
function count = getSeriesCount(spec)
    switch spec.kind
        case 'timeseries'
            count = numel(spec.seriesCell);
        otherwise
            count = 2;  % commEbNo and commLoss always have 2 series
    end
end

% -----------------------------------------------------------------------------
% resolveSeriesLimits  –  Compute y-axis limits for a time-series item at init
%
% For standard time-series, limits come from the spec data.
% For comm items, all four possible series (both sims, both directions) are
% pooled so the y-axis does not rescale when the active band switches.
% Bar items use their explicitly defined yLimits.
% A zero-range interval is widened to [-1, 1] to prevent a degenerate axis.
% -----------------------------------------------------------------------------
function limits = resolveSeriesLimits(spec, ~, ~)
    switch spec.kind
        case 'timeseries'
            limits = paddedLimitsFromCells(spec.seriesCell);
        case 'commEbNo'
            % Pool both UHF (sim 1) and S-band (sim 2) downlink/uplink Eb/No
            limits = paddedLimitsFromCells({safeSeriesCache(1, 1), safeSeriesCache(1, 2), safeSeriesCache(2, 1), safeSeriesCache(2, 2)});
        case 'commLoss'
            % Pool both UHF (sim 1) and S-band (sim 2) downlink/uplink loss
            limits = paddedLimitsFromCells({safeSeriesCache(1, 7), safeSeriesCache(1, 8), safeSeriesCache(2, 7), safeSeriesCache(2, 8)});
        otherwise
            limits = [0 1];
    end

    % Widen a zero-range interval to prevent axis rendering errors
    if diff(limits) <= eps
        limits = limits + [-1 1];
    end

    % Bar items always use their predefined limits
    if strcmp(spec.kind, 'bar')
        limits = spec.yLimits;
    end

    % Nested helper: read a channel from the cached runtime big_mat
    function values = safeSeriesCache(simIdx, paramIdx)
        values = safeSeries(getRuntimeBigMat(), simIdx, paramIdx);
    end
end

% -----------------------------------------------------------------------------
% loadOptionalNumericSeries  –  Load a named scalar series from the data struct
%   or base workspace, resampling to targetLength via the specified method.
%
% Falls back to a constant vector of fallbackValue if the field is absent.
% -----------------------------------------------------------------------------
function values = loadOptionalNumericSeries(data, fieldName, targetLength, fallbackValue, method)
    if isfield(data, fieldName)
        raw = data.(fieldName);
    else
        raw = [];
        try
            % Check the MATLAB base workspace as a secondary source
            if evalin('base', sprintf('exist(''%s'',''var'')', fieldName))
                raw = evalin('base', fieldName);
            end
        catch
            raw = [];
        end
    end

    values = normalizeNumericSeries(raw, targetLength, fallbackValue, method);
end

% -----------------------------------------------------------------------------
% normalizeNumericSeries  –  Resample or broadcast a 1-D numeric series
%
% Handles:
%   empty input   → constant fallback vector
%   all NaN       → constant fallback vector
%   single sample → broadcast constant
%   general case  → interp1 with the specified method; NaN outputs replaced
% -----------------------------------------------------------------------------
function values = normalizeNumericSeries(raw, targetLength, fallbackValue, method)
    if isempty(raw)
        values = fallbackValue * ones(1, targetLength);
        return;
    end

    raw = raw(:).';  % Ensure row vector
    validMask = isfinite(raw);

    if ~any(validMask)
        % All NaN — return the fallback constant
        values = fallbackValue * ones(1, targetLength);
        return;
    end

    if nnz(validMask) == 1
        % Single valid sample — broadcast it across all frames
        values = raw(find(validMask, 1, 'first')) * ones(1, targetLength);
        return;
    end

    % General case: resample from the original frame count to targetLength
    xOld   = linspace(1, targetLength, numel(raw));
    xNew   = 1:targetLength;
    values = interp1(xOld(validMask), raw(validMask), xNew, method, 'extrap');

    % Replace any residual NaN/Inf (e.g. from extrapolation) with the fallback
    values(~isfinite(values)) = fallbackValue;
end

% -----------------------------------------------------------------------------
% normalizeVectorSeries  –  Resample a [N x 3] direction vector series and
%   re-normalise each row to unit length after interpolation
% -----------------------------------------------------------------------------
function values = normalizeVectorSeries(raw, targetLength, method)
    values = zeros(targetLength, size(raw, 2));
    xOld   = linspace(1, targetLength, size(raw, 1));
    xNew   = 1:targetLength;

    for col = 1:size(raw, 2)
        series    = raw(:, col).';
        validMask = isfinite(series);
        if ~any(validMask)
            continue;  % Leave column as zero if no valid data
        end

        if nnz(validMask) == 1
            % Single valid sample — broadcast
            values(:, col) = series(find(validMask, 1, 'first'));
        else
            values(:, col) = interp1(xOld(validMask), series(validMask), xNew, method, 'extrap').';
        end
    end

    % Re-normalise every row to unit length (direction vectors must be unit)
    rowNorm   = vecnorm(values, 2, 2);
    validRows = rowNorm > eps;
    values(validRows, :) = values(validRows, :) ./ rowNorm(validRows);
end

% -----------------------------------------------------------------------------
% computeElevationSeries  –  Compute the elevation angle (deg) at each frame
%
% Elevation = the angle between the line-of-sight vector (sat - gs) and the
% local horizontal plane at the ground station, which equals:
%   asin(dot(los_unit, up_unit))
% where up_unit is the outward normal at the ground station (gsXYZ / |gsXYZ|).
% -----------------------------------------------------------------------------
function elevation = computeElevationSeries(satXYZ, gsXYZ)
    numSteps  = size(satXYZ, 1);
    elevation = nan(1, numSteps);

    for idx = 1:numSteps
        satPoint = satXYZ(idx, :);
        gsPoint  = gsXYZ(idx, :);

        % Skip frames with missing data
        if ~all(isfinite(satPoint)) || ~all(isfinite(gsPoint))
            continue;
        end

        los     = satPoint - gsPoint;   % Line-of-sight vector (ECI frame)
        losNorm = norm(los);
        gsNorm  = norm(gsPoint);

        % Skip degenerate cases (zero-length vectors)
        if losNorm <= eps || gsNorm <= eps
            continue;
        end

        upHat = gsPoint / gsNorm;              % Local vertical unit vector at ground station
        elevation(idx) = asind(dot(los / losNorm, upHat));  % Elevation in degrees
    end

    % Forward-fill remaining NaN values using the derived fallback (zeros)
    elevation = fillMissingVectorWithFallback(elevation, zeros(1, numSteps));
end

% -----------------------------------------------------------------------------
% safeSeries  –  Extract a single [1 x numSteps] parameter series from big_mat
%
% Returns a row of NaN values if the requested simulation or parameter index
% is out of bounds, rather than throwing an error.
% -----------------------------------------------------------------------------
function seriesData = safeSeries(big_mat, simIdx, paramIdx)
    if simIdx > size(big_mat, 1) || paramIdx > size(big_mat, 2)
        % Index out of bounds — return NaN vector of the correct length
        seriesData = nan(1, size(big_mat, 3));
        return;
    end

    seriesData = squeeze(big_mat(simIdx, paramIdx, :)).';
    if isempty(seriesData)
        seriesData = nan(1, size(big_mat, 3));
    end
end

% -----------------------------------------------------------------------------
% fillMissingVectorWithFallback  –  Replace NaN values in a vector with fallback
%
% Algorithm:
%   1. Substitute fallback values at positions that are NaN in primary.
%   2. If everything is still NaN, zero-fill and return.
%   3. Pad the leading segment (before the first finite value) with that value.
%   4. Forward-fill the rest: each NaN takes the value of its left neighbour.
% -----------------------------------------------------------------------------
function out = fillMissingVectorWithFallback(primary, fallback)
    out      = primary(:).';
    fallback = fallback(:).';

    % Truncate both to the shorter length if they differ in size
    if numel(fallback) ~= numel(out)
        n        = min(numel(fallback), numel(out));
        out      = out(1:n);
        fallback = fallback(1:n);
    end

    % Fill positions where primary is NaN/Inf from the fallback
    missingMask = ~isfinite(out);
    out(missingMask) = fallback(missingMask);

    % If still all invalid, zero-fill
    if all(~isfinite(out))
        out(:) = 0;
        return;
    end

    % Pad left side with the first valid value
    firstValid = find(isfinite(out), 1, 'first');
    out(1:firstValid-1) = out(firstValid);

    % Forward-fill remaining NaN values
    for idx = firstValid + 1:numel(out)
        if ~isfinite(out(idx))
            out(idx) = out(idx - 1);
        end
    end
end

% -----------------------------------------------------------------------------
% fillMissingMatrix  –  Apply column-wise forward-fill to a matrix
%
% Each column is treated independently: leading NaN rows are back-filled
% from the first valid value; subsequent NaN cells are forward-filled.
% Columns that are entirely NaN are set to zero.
% -----------------------------------------------------------------------------
function out = fillMissingMatrix(in)
    out = in;
    for col = 1:size(out, 2)
        values    = out(:, col);
        validMask = isfinite(values);

        if ~any(validMask)
            % Entire column is invalid — zero-fill
            values(:) = 0;
            out(:, col) = values;
            continue;
        end

        % Pad leading NaN rows with the first valid value
        firstValid = find(validMask, 1, 'first');
        values(1:firstValid-1) = values(firstValid);

        % Forward-fill subsequent NaN values
        for idx = firstValid + 1:numel(values)
            if ~isfinite(values(idx))
                values(idx) = values(idx - 1);
            end
        end

        out(:, col) = values;
    end
end

% -----------------------------------------------------------------------------
% selectFiniteScalar  –  Return the first finite element from a vector
%
% Returns fallbackValue if no finite element is found.
% -----------------------------------------------------------------------------
function value = selectFiniteScalar(values, fallbackValue)
    idx = find(isfinite(values), 1, 'first');
    if isempty(idx)
        value = fallbackValue;
    else
        value = values(idx);
    end
end

% -----------------------------------------------------------------------------
% sanitizeBooleanLike  –  Convert a numeric vector to a logical vector
%
% NaN/Inf values are treated as false (0).  Any value > 0.5 is treated as true.
% -----------------------------------------------------------------------------
function tf = sanitizeBooleanLike(values)
    values = values(:).';
    values(~isfinite(values)) = 0;  % Treat NaN/Inf as false
    tf = values > 0.5;
end

% -----------------------------------------------------------------------------
% nextValidFrame  –  Advance one step, wrapping around and skipping bad frames
%
% Increments the frame counter, wraps at numSteps, and skips over any frames
% where validFrameMask is false.  Returns the current frame if no valid frame
% can be found (i.e. all frames are invalid).
% -----------------------------------------------------------------------------
function frameIdx = nextValidFrame(orbitData, currentFrame)
    frameIdx = currentFrame + 1;

    % Wrap to the beginning when reaching the end
    if frameIdx > orbitData.numSteps
        frameIdx = 1;
    end

    % Skip invalid (NaN) frames; stop if we've looped all the way back
    while ~orbitData.validFrameMask(frameIdx)
        frameIdx = frameIdx + 1;
        if frameIdx > orbitData.numSteps
            frameIdx = 1;
        end
        if frameIdx == currentFrame
            break;  % All frames are invalid — stay on the current frame
        end
    end
end

% -----------------------------------------------------------------------------
% paddedLimitsFromCells  –  Compute y-axis limits from a cell array of vectors
%
% Pools all finite values across all cell elements, finds [min, max], and adds
% 8% padding on each side.  Returns [-1, 1] if there are no finite values.
% If min == max, padding is at least 1 unit to avoid a degenerate axis.
% -----------------------------------------------------------------------------
function limits = paddedLimitsFromCells(seriesCell)
    allData = [];
    for idx = 1:numel(seriesCell)
        values  = seriesCell{idx}(:);
        values  = values(isfinite(values));
        allData = [allData; values]; %#ok<AGROW>
    end

    if isempty(allData)
        limits = [-1 1];
        return;
    end

    minVal = min(allData);
    maxVal = max(allData);

    if minVal == maxVal
        % Zero-range data: add at least 1 unit of padding either side
        padding = max(1, 0.1 * max(abs(minVal), 1));
    else
        padding = 0.08 * (maxVal - minVal);  % 8% of the data range
    end

    limits = [minVal - padding, maxVal + padding];
end

% -----------------------------------------------------------------------------
% meanFinite  –  Compute the mean of all finite elements in a vector
%
% Returns fallbackValue if there are no finite elements.
% -----------------------------------------------------------------------------
function value = meanFinite(values, fallbackValue)
    values = values(isfinite(values));
    if isempty(values)
        value = fallbackValue;
    else
        value = mean(values);
    end
end

% -----------------------------------------------------------------------------
% blendColor  –  Linearly interpolate between two RGB colours
%
% out = (1 - mixRatio) * a + mixRatio * b
% mixRatio = 0 → pure a;  mixRatio = 1 → pure b.
% -----------------------------------------------------------------------------
function out = blendColor(a, b, mixRatio)
    out = (1 - mixRatio) * a + mixRatio * b;
end

% -----------------------------------------------------------------------------
% unitVector  –  Normalise a 3-element vector to unit length
%
% Returns [0 0 0] if the input contains non-finite values or has zero magnitude.
% -----------------------------------------------------------------------------
function vec = unitVector(vec)
    if ~all(isfinite(vec)) || norm(vec) <= eps
        vec = [0 0 0];
    else
        vec = vec / norm(vec);
    end
end

% -----------------------------------------------------------------------------
% ternary  –  Return trueValue or falseValue based on a scalar condition
%
% Mimics the C ternary operator (condition ? trueValue : falseValue).
% Useful for choosing between two scalar/string values inline.
% -----------------------------------------------------------------------------
function value = ternary(conditionValue, trueValue, falseValue)
    if conditionValue
        value = trueValue;
    else
        value = falseValue;
    end
end

% -----------------------------------------------------------------------------
% logicalText  –  Convert a boolean to the string 'Yes' or 'No'
% -----------------------------------------------------------------------------
function txt = logicalText(tf)
    if tf
        txt = 'Yes';
    else
        txt = 'No';
    end
end

% -----------------------------------------------------------------------------
% numericModeToString  –  Convert s.mode integer to opMode string
%
% Mapping:
%   1, 2  → ignored; returns currentMode unchanged
%   3     → 'Safe'    (big_mat power rows 3 and 6)
%   4     → 'Nominal' (big_mat power rows 4 and 7)
%   5     → 'Peak'    (big_mat power rows 5 and 8)
% -----------------------------------------------------------------------------
function modeStr = numericModeToString(numMode, currentMode)
    switch numMode
        case 3
            modeStr = 'Safe';
        case 4
            modeStr = 'Nominal';
        case 5
            modeStr = 'Peak';
        otherwise
            % Modes 1 and 2 (and any unexpected value) — hold current mode
            modeStr = currentMode;
    end
end