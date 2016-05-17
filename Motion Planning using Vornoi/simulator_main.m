close all; clear ; clc;
%% RANDOM SEED
% Reset random generator to initial state for repeatability of tests
SEED = 23426;
RandStream.setDefaultStream(RandStream('mt19937ar', 'Seed', SEED));

% Simulator
TURNS = 20; % Number of turns to simulate
N = 150; % Number of points in playing field
BBOX = [0 0 100 100]; % playing field bounding box [x1 y1 x2 y2]
global_goal = [50 70]; % Global goal position (must be in BBOX)
MINDIST = 0.1; % Minimum distance for UAV from goal score consider win

% Robot
robot_pos = [10 10]; % x,y position
robot_rov = 40; % Range of view
DMAX = robot_rov/5; % max UAV movement in one turn
TRAIL_STEP_SIZE = 0.2; % minimum distance of each trail step % Robot still traveld DMAX steps (just only saves trail every trail-step-size)
TREE_SIZE = 2.2;    %The minimum distance we can pass from a tree. 
                    %Affects which Voronoi edges are pruned in global
                    %and cost of getting close to a tree in local
TOO_CLOSE_TO_TREE = 0.5; %Closest we can approach a tree without collision

USE_VISIBLE_OBSTACLES_ONLY = false; % Voronoi global only uses visible obstacles (instead of all known-of obstacles)

%Criteria incase it gets stuck in Global mode
LOCAL_GOAL_DIST_MAX = robot_rov/1.9; % Max Distance to choose local goal from a* plan
LOCAL_GOAL_DIST_MIN = 0.1; % Min distance to choose local goal from (PS, this has to be > 0, as 0 will return the current location as the local goal!)
LOCAL_GOAL_DIST_DEGRADE = 0.5; % Rate of choosing closer goals when stuck in minima
LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MAX; % Current distance for choosing local goal (decays/changes)
LOCAL_GOAL_DIST_RECOVER = 6; %Number of turns for LOCAL_GOAL_DIST to recover to robot_rov after being stuck
STUCK_TIME = 30; %Number of points in a row that must be near each other to be considered stuck

%Criteria incase it gets stuck in Local Mode
LOCAL_DIST_FORCE_MIN = TREE_SIZE;
LOCAL_DIST_FORCE_MAX = 2 * TREE_SIZE;
LOCAL_DIST_FORCE = LOCAL_DIST_FORCE_MIN; % Amount of force obstacles distance has on potential field
LOCAL_DIST_FORCE_STEP = 1;
LOCAL_DIST_FORCE_DEGRADE_RATE = 0.9; % Rate per turn of reduction of LOCAL_DIST_FORCE
LOCAL_STUCK_MINIMA_THRESHOLD = 0.1; % Threshold at which local_goal_path std considered stuck


% FIGURES (LOCAL - contour, and GLOBAL - 2d trail)
SHOW_ACTUAL_OBSTACLES = true; % whether to plot ground truth position of obstacles or not
SHOW_VORONOI_OVERLAY = true;
SHOW_LOCAL_FIGURE = false; % plot local planner contour figure
SHOW_LOCAL_ON_GLOBAL_AXIS = false; % Plot local area of contour on entire BBOX versus local
FIG_SIZE = 1.5*[640 800];%[1900 1200]; % Both Figure sizes
FIG_POS1 = [10 10];%[1910 10];% Local figure position
FIG_POS2 = [550 10]; %[10 10];% Global figure position
LEGEND_ON = false; % Whether to show legend or not
LEGEND_POS = 'SouthOutside';

% AVI FILES
COMPRESSION = 'FFDS'; 
Global_filename = sprintf('simAll_2D_Present_ROV%i_N%i_C.avi',robot_rov,N); 
Local_filename = sprintf('simAll_Contour_Present_ROV%i_N%i_C.avi',robot_rov,N);
DO_AVI = false; % 
DO_LOCAL_AVI = true && SHOW_LOCAL_FIGURE; 
FRAME_REPEATS = 2; % Number of times to repeat frame in avi (slower framerate below 5 fails on avifile('fps',<5))

% Noise Function
[noiseFilt sigmaV] = noiseFilterDist(); %noiseFilt = makeNoiseFilter(0,0.4,30,10,1.4);
%sigmaV = @(x) 0; % Zero sigma function
LOW_NOISE_CONFIDENCE_THRESHOLD = 0.7; 



%% SETUP
getRandPoints = @(N,x1,y1,x2,y2) [ones(1,N)*x1; ones(1,N)*y1] + rand(2,N).*[ones(1,N)*(x2-x1); ones(1,N)*(y2-y1)];

getRandNormalPoints = @(N,x1,y1,x2,y2) repmat([(x2-x1)/2 (y2-y1)/2],N,1)' + randn(2,N)*min(x2-x1,y2-y1)/5;
getDist = @(a,b) sqrt((b(:,2)-a(2)).^2 + (b(:,1)-a(1)).^2); 
obstacles = getRandNormalPoints(N,BBOX(1),BBOX(2),BBOX(3),BBOX(4)); 


views = zeros(1,N); % Number of times point has been seen before, this affects the noiseFilter as value passed into viewsCount (more = less noise)
obstacleEstimate = zeros(2,N); % Last (estimated) Known position of obstacles
obstacleLastKnown = zeros(2,N); % Last known all obstacles
distances = zeros(1, N); % Init current distances between robot and obstacles
robot_trail = robot_pos;%zeros(TURNS,2); % Initialize robot position history
local_goal_path = [];


noPathExists = false;
%local_goal = global_goal;


% Axis & Views
AX = [BBOX(1),BBOX(3),BBOX(2),BBOX(4)];
azel = [-123.5 58]; % for view in saving files
closestEncounter = inf; % Closest distance of robot to any obstacle
closestPos = [0,0]; % Position of closest encounter

% Run loop variables
foundGoal = 0;
checkRepeat0It = 0;


% Setup AVI files
if DO_AVI
    aviobj = avifile(Global_filename,'compression',COMPRESSION,'fps',5); % Global AVI
    if DO_LOCAL_AVI
        aviobj2 = avifile(Local_filename,'compression',COMPRESSION,'fps',5); % Local AVI
    end
end

%% Set up Figures
if SHOW_LOCAL_FIGURE
    fh1 = figure(1); % 3D Contour Figure (Left)
    pos = get(gcf, 'position');
    pos(1:2) = FIG_POS1;
    pos(3:4) = FIG_SIZE;
    set(gcf, 'position', pos);
end

fh2 = figure(2); % Ground Truth Figure with Voronoi (Right)
axis(AX);
pos = get(fh2, 'position');
pos(1:2) = FIG_POS2;
pos(3:4) = FIG_SIZE;
set(fh2, 'position', pos);

%% RUN LOOP
fprintf(2,'  Magenta Diamond - UAV position\n');
fprintf(2,'        Blue Star - Local Goal\n');
fprintf(2,'         Red Star - Global Goal\n');
fprintf(2,'        Black dot - Ground truth positions of obstacles (unknown to UAV)\n');
fprintf(2,'        Green dot - Last known observed position of obstacle (connected to ground truth position with green dotted line)\n');
fprintf(2,'Blue dotted-lines - Voronoi diagram\n\n');




for i = 1:TURNS
   fprintf('TURN %i : ',i);
   
   % Calculate obstacle visibility etc. based on position
   distances = getDist(robot_pos,obstacles');
   visibleDistances = distances(distances<robot_rov);
   views(distances<robot_rov) = views(distances<robot_rov) + 1;
   viewCurrent = zeros(1,N); % localPlanner view sees only currently visible obstacles
   viewCurrent(distances<robot_rov) = 1; % only 1's and 0's for obstacles currently visible or not
   
   % The noise based on view count for all obstacles
   noise = noiseFilt(  views , distances' , 0.1 );
   %noise = noiseFilt(  views , distances(distances<robot_rov) );
   
   % update noise only for those currently seeing 
   obstacleLastKnown(:,viewCurrent~=0) = obstacles(:,viewCurrent~=0) + noise(:,viewCurrent~=0);
   
   obstacleEstimate = obstacleLastKnown(:,views~=0); % only obstacles that have ever been visible
   obstacleCurrent = obstacleLastKnown(:,viewCurrent~=0); % Only currently visible obstacles (no 0's)
   
   obstacleObjects = cell(1,sum(viewCurrent));
   for k = 1:sum(viewCurrent)
       obstacleObjects{k}.x = obstacleCurrent(1,k);
       obstacleObjects{k}.y = obstacleCurrent(2,k);
       v = views(logical(viewCurrent));
       obstacleObjects{k}.sig = sigmaV(v(k),visibleDistances(k),0.1);
       %obstacleObjects{k}.sig = sigmaV(v(k));
   end
   
   %% RUN PLANNERS---------------------------------------------------------
   
   %%% VORONOI PLANNER - Determine Local Goal given known obstacles, and global goal
   
   % Average Noise 'distance' of visible obstacles
   avgNoiseVisibleObstacles = sum(sqrt(sum( noise(:,viewCurrent~=0).^2  ,1))) / sum(viewCurrent);
   if size(obstacleCurrent,2) == 0  % If no obstacles present...
       local_goal = global_goal; %robot_pos+20*(global_goal-robot_pos)/getDist(robot_pos,global_goal); % 10% towards global_goal
       VX = [];VY = [];VXnew = [];VYnew = [];PX = [];PY = [];
       
   elseif i == 1 || (avgNoiseVisibleObstacles > LOW_NOISE_CONFIDENCE_THRESHOLD) || (~noPathExists && getDist(robot_pos,local_goal) < DMAX || ... % if very confident (low noise) or no obstacles
           LOCAL_GOAL_DIST < LOCAL_GOAL_DIST_MAX || LOCAL_DIST_FORCE > LOCAL_DIST_FORCE_MIN)    %Ensure that if we're stuck in a local minimum, we use voronoi anyway
       if USE_VISIBLE_OBSTACLES_ONLY
           [local_goal,noPathExists,VX,VY,VXnew,VYnew,PX,PY] = voronoi_planner(obstacleCurrent', robot_pos, global_goal, TREE_SIZE*1.2, LOCAL_GOAL_DIST);
       else
           [local_goal,noPathExists,VX,VY,VXnew,VYnew,PX,PY] = voronoi_planner(obstacleEstimate', robot_pos, global_goal, TREE_SIZE*1.2, LOCAL_GOAL_DIST);
       end
       
   else
       disp('Low noise - continuing previous Voronoi path');
   end
   % If no path exists and uncertainty is below min threshold, assume
   % we're stuck for good
   noMove = false;
   done = false;
   if noPathExists 
       if (avgNoiseVisibleObstacles < LOW_NOISE_CONFIDENCE_THRESHOLD)
           disp('No Path exists, game off.');
           noMove = true;
           done = true;
       else
           disp('No Path exists, waiting for uncertain obstacles to converge.');
           noMove = true;
       end
   end

   %%% LOCAL PLANNER - must come before Update Robot (needs local_goal and robot position)
   if (~noMove)
       % If Voronoi is being bad, ignore it
       if (getDist(robot_pos,local_goal) > getDist(robot_pos,global_goal))
           local_goal = global_goal; % global goal is closer than local goal
       end
       
       local_goal_path = localplan(robot_pos, local_goal, obstacleObjects, LOCAL_DIST_FORCE); % Only given those obstacles it currently sees

       %%% If current path is stuck in a local minima, increase effect of obstacle distances
       % Update local force effect
       if (LOCAL_DIST_FORCE*LOCAL_DIST_FORCE_DEGRADE_RATE > LOCAL_DIST_FORCE_MIN)
           LOCAL_DIST_FORCE = LOCAL_DIST_FORCE*LOCAL_DIST_FORCE_DEGRADE_RATE;
       else
           LOCAL_DIST_FORCE = LOCAL_DIST_FORCE_MIN;
       end

       % Check if local path is stuck in minima, if so change force & local
       % goal to closer
       if (sum(std(local_goal_path).^2) < LOCAL_STUCK_MINIMA_THRESHOLD)
           if (LOCAL_DIST_FORCE + LOCAL_DIST_FORCE_STEP < LOCAL_DIST_FORCE_MAX)
               LOCAL_DIST_FORCE = LOCAL_DIST_FORCE + LOCAL_DIST_FORCE_STEP;
           end
           if LOCAL_GOAL_DIST*LOCAL_GOAL_DIST_DEGRADE > LOCAL_GOAL_DIST_MIN
               LOCAL_GOAL_DIST = LOCAL_GOAL_DIST*LOCAL_GOAL_DIST_DEGRADE;
           else
               LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MIN;
           end
           fprintf('Force : %g, Goal-Dist : %g\n' , LOCAL_DIST_FORCE,LOCAL_GOAL_DIST);
       end
    
   end
   
   
   %% START GLOBAL PLOT 
   figure(fh2);
   %hold off;
   clf;
   hold on;
   
   % Plot VORONOI LINES
   if SHOW_VORONOI_OVERLAY
       plot(VX,VY,':','Color',[0.8 0.8 0.8]); 
       plot(PX,PY,'y','LineWidth',5);  
       plot(VXnew,VYnew,'b:');   
       set(fh2(1:end-1),'xliminclude','off','yliminclude','off'); % keep infinite lines clipped
   end
   
   % Observed Obstacles
   if USE_VISIBLE_OBSTACLES_ONLY
       observedObsH = scatter(obstacleCurrent(1,:),obstacleCurrent(2,:),'g','filled');
   else
       observedObsH = scatter(obstacleEstimate(1,:),obstacleEstimate(2,:),'g','filled');
   end
   axis('equal'); axis(AX);
   
   
   % UAV
   plot([robot_trail(robot_trail(:,1)~=0,1); robot_pos(1)],[robot_trail(robot_trail(:,2)~=0,2); robot_pos(2)],'b.-'); 
   robotPosH = scatter(robot_pos(1), robot_pos(2),80, 'md','filled'); 
   drawCircle(robot_pos(1),robot_pos(2), robot_rov, 'b-'); 
   
   % Local & Global Goals
   if (~noMove)
        localGoalH = scatter(local_goal(1),local_goal(2),100,'cp','filled'); % Plot local goal
   end
   %globalGoalH = scatter(global_goal(1),global_goal(2),150,'rp','filled'); % Plot global goal 
   
   if SHOW_ACTUAL_OBSTACLES
       % Ground truth - black
       groundTruthH = scatter( obstacles(1,:),obstacles(2,:),150,'k.');
       if LEGEND_ON
           if (noMove)
               legend([robotPosH globalGoalH observedObsH groundTruthH],'UAV position','Global Goal', 'Observed/Estimated Obstacle Positions', 'Ground Truth Obstacle Positions','Location',LEGEND_POS);
           else
               legend([robotPosH localGoalH globalGoalH observedObsH groundTruthH],'UAV position','Local Goal','Global Goal', 'Observed/Estimated Obstacle Positions', 'Ground Truth Obstacle Positions','Location',LEGEND_POS);
           end
       end
   elseif LEGEND_ON
       if (noMove)
           legend([robotPosH globalGoalH observedObsH],'UAV position','Global Goal', 'Observed/Estimated Obstacle Positions','Location',LEGEND_POS);
       else
           legend([robotPosH localGoalH globalGoalH observedObsH],'UAV position','Local Goal','Global Goal', 'Observed/Estimated Obstacle Positions','Location',LEGEND_POS);
       end
   end
   
   title(sprintf('%i Obstacles, Turn %i : Distance to Global Goal = %g\nClosest Encounter = %g @ P(%g,%g)',N,i,getDist(robot_pos,global_goal),closestEncounter,closestPos(1),closestPos(2)));
   hold off;
   
   %% AVI of Global
   if DO_AVI
       f2 = getframe(fh2);
       for k = 1:FRAME_REPEATS
           aviobj = addframe(aviobj,f2); % Save to avi
       end
   end   
   
   
   %% START LOCAL PLOT - 3D Contour path for LOCAL Planner 
   
   if SHOW_LOCAL_FIGURE && size(local_goal_path,1) > 1 % also can't plot if there is no path
       if SHOW_LOCAL_ON_GLOBAL_AXIS
           plotlocal(obstacleObjects, local_goal, global_goal, local_goal_path, LOCAL_DIST_FORCE, AX ,fh1); % new figure 3d contour
       else
           plotlocal(obstacleObjects, local_goal, global_goal, local_goal_path, LOCAL_DIST_FORCE, '' ,fh1); % new figure 3d contour
       end
       axis('equal'); axis(AX);
       view(azel);
       view(2);

       %% AVI for Local
       title(sprintf('Turn %i : Distance to Local Goal = %g',i,getDist(robot_pos,global_goal)));
       if DO_AVI && DO_LOCAL_AVI
           f1 = getframe(fh1);
           for k=1:FRAME_REPEATS
               aviobj2 = addframe(aviobj2,f1); % Save to avi
           end
       end
   end 
   
   %% Update Robot 
   if (~noMove)
       d = 0; k = 0;
       if getDist(robot_pos,global_goal) < MINDIST  % Found the goal!
           foundGoal = foundGoal + 1;
       end
       % Update Robot position along local path trail for distance DMAX
       while (d < DMAX && 2+k <= size(local_goal_path,1))
           if getDist(robot_pos,global_goal) < MINDIST  % Found the goal!
               if foundGoal == 1
                   disp('Almost there...');
               end
               foundGoal = foundGoal + 1;
               robot_pos = global_goal;
               robot_trail(end+1,:) = robot_pos;
               break
           end
           
           
           next_pos = local_goal_path(2+k,:); % choose next position from local plan
           d = d + getDist(robot_pos,next_pos); % distance traveled increased by motion
           k = k + 1; % next point in path
           % Update position
           if (d > DMAX)
               
               next_pos = robot_pos + (DMAX-d+getDist(robot_pos,next_pos))*(next_pos-robot_pos)/getDist(robot_pos,next_pos);
           end
           
           %% Find closest encounter to ground truth obstacles
           p1 = robot_trail(end,:);
           p2 = next_pos;
           mindist = Inf;
           for l = 1:N
               p0 = obstacles(:,l)';
               m = (p2(2)-p1(2))/(p2(1)-p1(1));
               if ((isinf(m) && p0(2) > min(p1(2),p2(2)) && p0(2) < max(p1(2),p2(2))) || ...
                       (m == 0 && p0(1) > min(p1(1),p2(1)) && p0(1) < max(p1(1),p2(1))))
                   dist = abs((p2(1)-p1(1))*(p1(2)-p0(2))-(p1(1)-p0(1))*(p2(2)-p1(2)))/sqrt((p2(1)-p1(1))^2+(p2(2)-p1(2))^2);
               elseif (~isinf(m) && m ~= 0)
                   xint = (1-m^2)/m * (p1(2) - p0(2) + m*p1(1) - 1/m*p0(1));
                   yint = m * (xint - p1(1)) + p1(2);
                   if (xint > min(p1(1),p2(1)) && xint < max(p1(1),p2(1)) && yint > min(p1(2),p2(2)) && yint < max(p1(2),p2(2)))
                       dist = abs((p2(1)-p1(1))*(p1(2)-p0(2))-(p1(1)-p0(1))*(p2(2)-p1(2)))/sqrt((p2(1)-p1(1))^2+(p2(2)-p1(2))^2);
                   else
                       dist = Inf;
                   end
               else
                   dist = Inf;
               end
               if (getDist(p2,p0) < dist)
                   dist = getDist(p2,p0);
               end
               if (dist < mindist)
                   mindist = dist;
               end
           end
           
           if (mindist > TOO_CLOSE_TO_TREE)
               if (getDist(robot_trail(end,:),robot_pos) >= TRAIL_STEP_SIZE)
                   robot_trail(end+1,:) = robot_pos; % Keep history of robot positions;
               end
               robot_pos = next_pos;
               if (mindist < closestEncounter)
                   closestEncounter = mindist;
                   closestPos = p2;
               end
           else
               disp('Almost hit a tree, ending this move.');
               break;
           end
       end
   end
   
   %% Check End State or Stuck State
   if (foundGoal == 2) % If we found goal, we're done!
       fprintf('You made it in %i steps.\n',i);
       done = true;
   end
   if (length(robot_trail) > STUCK_TIME && sum(std(robot_trail(end-STUCK_TIME:end,:)).^2) < 0.3) % If last 10 points were roughly same spot, we're stuck and done.
       disp('Stuck in Loop.') 
   end
   
   % Recover goal distance to normal
   if (LOCAL_GOAL_DIST < LOCAL_GOAL_DIST_MAX)
       LOCAL_GOAL_DIST = LOCAL_GOAL_DIST + LOCAL_GOAL_DIST_MAX/LOCAL_GOAL_DIST_RECOVER;
       if (LOCAL_GOAL_DIST > LOCAL_GOAL_DIST_MAX)
           LOCAL_GOAL_DIST = LOCAL_GOAL_DIST_MAX;
       end
   end
   if (done)
       break;
   end
   %pause
   pause(0.001);
end

%% Close AVI files
if DO_AVI
    aviobj = close(aviobj);
    fprintf('\nSaved global voronoi path and robot movement overlay movie to ''%s'' : ',Global_filename);
    fprintf('Global (Voronoi) Path Plan with %i obstacles\n',N);
    if DO_LOCAL_AVI
        aviobj2 = close(aviobj2);
        fprintf('Saved local potential field path movie to ''%s'' : ',Local_filename);
        fprintf('Local (Potential Field) Path Plan with %i obstacles\n',N);
    end
end