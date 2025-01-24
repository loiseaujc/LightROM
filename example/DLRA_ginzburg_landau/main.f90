program demo
   ! Standard Library.
   use stdlib_optval, only : optval 
   use stdlib_linalg, only : eye, diag, eig
   use stdlib_math, only : all_close, logspace
   use stdlib_io_npy, only : save_npy, load_npy
   use stdlib_logger, only : information_level, warning_level, debug_level, error_level, none_level
   ! LightKrylov for linear algebra.
   use LightKrylov
   use LightKrylov, only : wp => dp
   use LightKrylov_Logger
   use LightKrylov_AbstractVectors
   use LightKrylov_ExpmLib
   use LightKrylov_Utils
   ! LightROM
   use LightROM_AbstractLTIsystems
   use LightROM_Utils
   use LightROM_Timing
   use LightROM_LyapunovSolvers
   use LightROM_LyapunovUtils
   ! GInzburg-Landau
   use Ginzburg_Landau_Base
   use Ginzburg_Landau_Operators
   use Ginzburg_Landau_Utils
   use Ginzburg_Landau_Tests
   implicit none

   character(len=*), parameter :: this_module = 'Ginzburg_Landau_Main'

   character(len=128), parameter :: home = 'example/DLRA_ginzburg_landau/local/'
   character(len=128) :: onameU, onameS, oname
   ! rk_B & rk_C are set in ginzburg_landau_base.f90

   integer  :: nrk, ntau, rk,  torder
   real(wp) :: tau, Tend, T_RK
   ! vector of dt values
   real(wp), allocatable :: dtv(:)
   ! vector of tolerances
   real(wp), allocatable :: tolv(:)
   ! vector of rank values
   integer, allocatable :: rkv(:)
   ! vector of temporal order
   integer, allocatable :: TOv(:)

   ! Exponential propagator (RKlib).
   type(GL_operator),            allocatable :: A
   type(exponential_prop),       allocatable :: prop

   ! LTI system
   type(lti_system)                          :: LTI
   type(dlra_opts)                           :: opts

   ! Initial condition
   type(state_vector),           allocatable :: U0(:), output(:)
   real(wp),                     allocatable :: S0(:,:)
   
   ! OUTPUT
   real(wp)                                  :: X_out(N,N)

   ! Reference solutions (BS & RK)
   real(wp)                                  :: Xref(N,N)
   real(wp)                                  :: Xref_RK(N,N)

   ! IO
   real(wp),                    allocatable :: U_load(:,:)
   
   ! POD
   real(wp),                    allocatable :: XTX(:,:)

   ! Information flag.
   integer                                   :: info

   ! Misc
   integer                                   :: i, j, k, it, irep, iref, is, ie
   integer                                   :: nsnap, nstep, nrank
   ! SVD & printing
   real(wp), dimension(:),       allocatable :: svals
   integer, parameter                        :: irow = 8
   integer                                   :: nprint
   logical                                   :: if_save_output
   character(len=128)                        :: msg
   integer                                   :: nout

   !--------------------------------
   ! Define which examples to run:
   !
   logical, parameter :: if_lyapunov = .false.
   !
   ! if_lyapunov = .true.:  Solve the Lyapunov equation:   0 = A @ X + X @ A.T + Q
   !
   ! if_lyapunov = .false.: Solve the Riccati equation:    0 = A @ X + X @ A.T + X @ B @ @ R^{-1} @ B.T @ W @ X + Q
   !
   logical, parameter :: adjoint = .true. !.false.
   ! Only considered if if_lyapunov = .true.
   !
   ! Adjoint = .true.:      Solve the adjoint Lyapunov equation:  0 = A.T @ X + X @ A + C.T @ C @ W
   !     The solution to this equation is called the observability Gramian Y.
   !
   ! Adjoint = .false.:     Solve the direct Lyapunov equation:   0 = A @ X + X @ A.T + B @ B.T @ W
   !     The solution to this equation is called the controllability Gramian X.
   !
   logical, parameter :: main_run = .false.
   !
   ! Run the computation instead of the test
   !
   logical, parameter :: short_test = .true.
   !
   ! Skip the computations with small dt/small tolerance to speed up test
   !
   logical, parameter :: run_fixed_rank_short_integration_time_test   = .true.
   !
   ! Integrate the same initial condition for a short time with Runge-Kutta and DLRA.
   !
   ! The solution will be far from steady state (the residual will be large) for both methods.
   ! This test shows the convergence of the method as a function of the step size, the rank
   ! and the temporal order of DLRA.
   ! Owing to the short integration time, this test is by far the fastest to run.
   !
   logical, parameter :: run_fixed_rank_long_integration_time_test    = .true.
   !
   ! Integrate the same initial condition to steady state with Runge-Kutta and DLRA.
   !
   ! As the steady state is approached, the error/residual for Runge-Kutta goes to zero.
   ! Similarly, the test shows the effect of step size, rank and temporal order on the solution
   ! using DLRA.
   !
   logical, parameter :: run_rank_adaptive_long_integration_time_test = .true.
   !
   ! Integrate the same initial condition to steady state with Runge-Kutta and DLRA using an 
   ! adaptive rank.
   !
   ! The DLRA algorthm automatically determines the rank necessary to integrate the equations
   ! such that the error on the singular values does not exceed a chosen tolerance. This rank
   ! depends on the tolerance but also the chosen time-step.
   !
   !--------------------------------

   ! Setup logging
   call logger_setup(logfile=trim(home)//'lightkrylov.log', log_level=error_level, log_stdout=.false., log_timestamp=.true.)

   ! Initialize timers for LightKrylov and LightROM
   call initialize_timers()
   call global_lightROM_timer%add_timer('DLRA Ginzburg-Landau example', start=.true.)
   call global_lightROM_timer%add_timer('Direct solution (LAPACK)', start=.true.)
   ! Enumerate timers to check proper initialization
   call enumerate_timers()

   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#               DYNAMIC LOW-RANK APPROXIMATION  -  DLRA                 #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   print *, ' LYAPUNOV EQUATION FOR THE NON-PARALLEL LINEAR GINZBURG-LANDAU EQUATION:'
   print *, ''
   print *, '                 A = mu(x) * I + nu * D_x + gamma * D2_x'
   print *, ''
   print *, '                   with mu(x) = mu_0 * x + mu_2 * x^2'
   print *, ''
   if (if_lyapunov) then
      print *, ''
      print '(13X,A,I4,"x",I4)', 'Complex problem size:          ', nx, nx
      print '(13X,A,I4,"x",I4)', 'Equivalent real problem size:  ', N, N
      print *, ''
      print *, '            Initial condition: rank(X0)  =', rk_X0
      print *, '            Inhomogeneity:     rank(B)   =', rk_B
      print *, '            Inhomogeneity:     rank(C.T) =', rk_C
   else
      print *, '                     Algebraic Riccati equation:'
      print *, '     0 = A.T @ X + X @ A - X @ B @ R^{-1} @ B.T @ X + C.T @ Qc @ C'
      print *, ''               
      print *, '                   Differential Riccati equation:'
      print *, '   \dot{X} = A.T @ X + X @ A - X @ B @ R^{-1} @ B.T @ X + C.T @ Qc @ C'
      print *, ''
      print '(13X,A,I4,"x",I4)', 'Complex problem size:                       ', nx, nx
      print '(13X,A,I4,"x",I4)', 'Equivalent real problem size:               ', N, N
      print *, ''
      print *, '            Initial condition: rank(X0)               =', rk_X0
      print *, '            Nonlinearity:      rank(B @ R^{-1} @ B.T) =', rk_b
      print *, '            Inhomogeneity:     rank(C.T @ Qc @ C)     =', rk_C
   end if
   print *, ''
   print *, '#########################################################################'
   print *, ''

   ! Initialize mesh and system parameters A, B, CT
   print '(4X,A)', 'Initialize parameters'
   call initialize_parameters()

   ! Initialize propagator
   print '(4X,A)', 'Initialize exponential propagator'
   prop = exponential_prop(1.0_wp)

   ! Initialize LTI system
   A = GL_operator()
   print '(4X,A)', 'Initialize LTI system (A, prop, B, CT, _)'
   LTI = lti_system()
   call LTI%initialize_lti_system(A, prop, B, CT)

   print *, ''
   if (adjoint) then
      svals = svdvals(CTCW)
      print '(1X,A,*(F16.12,X))', 'SVD(1:3) CTCW:   ', svals(1:3)
   else
      svals = svdvals(BBTW)
      print '(1X,A,*(F16.12,X))', 'SVD(1:3) BBTW:   ', svals(1:3)
   end if

   print *, ''
   if (if_lyapunov) then
      print *, 'Check residual computation with Bartels-Stuart solution:'
      if (adjoint) then
         oname = './example/DLRA_ginzburg_landau/CGL_Lyapunov_Observability_Yref_BS_W.npy'
      else
         oname = './example/DLRA_ginzburg_landau/CGL_Lyapunov_Controllability_Xref_BS_W.npy'
      end if
   else
      print *, 'Check residual computation with Schur decomposition method:'
      oname = './example/DLRA_ginzburg_landau/CGL_Riccati_Pref_Schur_W.npy'
   end if
   call load_npy(oname, U_load)
   Xref = U_load
   
   print *, ''
   print '(A,F16.12)', '  |  X_BS  |/N = ', norm2(Xref)/N
   if (if_lyapunov) then
      print '(A,F16.12)', '  | res_BS |/N = ', norm2(CALE(Xref, adjoint))/N
   else
      print '(A,F16.12)', '  | res_BS |/N = ', norm2(CARE(Xref, CTQcCW, BRinvBTW, adjoint))/N
   end if
   print *, ''
   ! compute svd
   svals = svdvals(Xref)
   print *, 'SVD X_BS:'
   do i = 1, ceiling(60.0/irow)
      is = (i-1)*irow+1; ie = i*irow
      print '(2X,I2,"-",I2,*(1X,F16.12))', is, ie, ( svals(j), j = is, ie )
   end do
   print *, ''
   
   ! Define initial condition
   allocate(U0(rk_X0), source=B(1)); call zero_basis(U0)
   allocate(S0(rk_X0,rk_X0)); S0 = 0.0_wp
   print *, 'Define initial condition'
   call generate_random_initial_condition(U0, S0, rk_X0)
   call reconstruct_solution(X_out, U0, S0)
   print *, ''
   print '(A,F16.12)', '  |  X_0  |/N = ', norm2(X_out)/N
   print '(A,F16.12)', '  | res_0 |/N = ', norm2(CALE(X_out, adjoint))/N
   print *, ''
   ! compute svd
   svals = svdvals(X_out)
   do i = 1, ceiling(rk_X0*1.0_wp/irow)
      is = (i-1)*irow+1; ie = i*irow
      print '(2X,I2,"-",I2,*(1X,F16.12))', is, ie, ( svals(j), j = is, ie )
   end do

   call global_lightROM_timer%stop('Direct solution (LAPACK)')
   call global_lightROM_timer%add_timer('Short time: Runge-Kutta', start=.true.)
   
   if (main_run) then
      ! DLRA with adaptive rank
      dtv  = logspace(-2.0_wp, 0.0_wp, 3, 10)
      dtv  = dtv(size(dtv):1:-1) ! reverse vector
      tolv = [ 1e-2_wp, 1e-6_wp, 1e-10_wp ]
      TOv  = [ 1, 2 ]
      
      open (1234, file='Lyap_case.log', status='replace', action='write')
      irep = 0
      do i = 1, size(tolv)
         do j = 1, size(TOv)
            do k = 1, size(dtv)
               irep= irep + 1
               write (1234, '(I3,A,E9.2,A,I1,A,F10.6)') irep, ': stol= ', tolv(i), ', TO= ', TOv(j), ', dt= ', dtv(k) 
            end do
         end do
      end do
      close (1234)

      nprint = 60
      if_save_output = .true.

      T_RK  = 120.0_wp
      nstep = 120
      iref  = 120
      Tend = T_RK/nstep*iref

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    Ia.  Solution using Runge-Kutta to steady state                    #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      call run_lyap_reference_RK(LTI, Xref, Xref_RK, U0, S0, T_RK, nstep, iref, adjoint)

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    Ib.  Solution using rank-adaptive DLRA                            #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      call run_lyap_DLRArk_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, TOv, tolv, nprint, adjoint, home, if_save_output)

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    Ic.  Solution using POD                                            #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

     
      tolv = [ 10.0_wp, 50.0_wp, 100.0_wp ]
      dtv  = logspace(-1.0_wp, 0.0_wp, 3, 10)
      dtv  = dtv(size(dtv):1:-1) ! reverse vector
      print '(1X,A)', 'POD:'
      do it = 1, size(tolv)
         Tend = tolv(it)
         print '(3X,A,F12.6)', '   Tend:', Tend
         do irep = 1, size(dtv)
            tau = dtv(irep)
            prop = exponential_prop(tau)
            nout = nint(Tend/tau)
            if (adjoint) then
               nrank = rk_C
            else
               nrank = rk_B
            end if
            nsnap = nrank*nout
            if (allocated(output)) deallocate(output)
            allocate(output(nsnap), source=CT(1))
            if (allocated(XTX)) deallocate(XTX)
            allocate(XTX(nsnap,nsnap))
            call zero_basis(output)
            ! Compute impulse response of input/output using direct/adjoint linear solver
            k = 0
            do j = 1, nrank
               do i = 1, nout - 1
                  k = k + 1
                  if (adjoint) then
                     if (i == 1)  then
                        call copy(output(k), CT(j)) ! initial condtion
                     end if
                     call prop%rmatvec(output(k), output(k+1))
                  else
                     if (i == 1)  then
                        call copy(output(k), B(j))  ! initial condtion
                     end if
                     call prop%matvec(output(k), output(k+1))
                  end if
                  call output(k)%scal(sqrt(tau))
               end do
            end do
            call innerprod(XTX, output, output)
            nprint = min(8, nsnap)
            svals = svdvals(XTX)
            do i = 1, ceiling(nprint*1.0_wp/irow)
               is = (i-1)*irow+1; ie = min(i*irow, nprint)
               print '(1X,A,F6.4,A,I2,A,I2,*(1X,F16.12))', 'SVD(XTX) [ dt=', tau,' ]', is, '-', ie, ( svals(j), j = is, ie )
            end do
         end do
      end do

   else
      
      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    Ia.  Solution using Runge-Kutta over a short time horizon          #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      if (run_fixed_rank_short_integration_time_test) then         
         if (if_lyapunov) then
            T_RK  = 0.01_wp
            nstep = 10
            iref  = 5
            ! Run RK integrator for the Lyapunov equation
            call run_lyap_reference_RK(LTI, Xref, Xref_RK, U0, S0, T_RK, nstep, iref, adjoint)
         else
            T_RK  = 0.01_wp
            nstep = 10
            iref  = 5
            ! Run RK integrator for the Riccati equation
            call run_lyap_reference_RK(LTI, Xref, Xref_RK, U0, S0, T_RK, nstep, iref, adjoint)
         end if
      else
         print *, 'Skip.'
         print *, ''
      end if

      call global_lightROM_timer%stop('Short time: Runge-Kutta')
      call global_lightROM_timer%add_timer('Short time: DLRA', start=.true.)
      
      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    Ib.  Solution using fixed-rank DLRA                                #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      if (run_fixed_rank_short_integration_time_test) then
         if (if_lyapunov) then
            Tend = T_RK/nstep*iref
            rkv = [ 10, 12, 16 ]
            if (short_test) then
               dtv = logspace(-3.0_wp, -3.0_wp, 1, 10)
            else
               dtv = logspace(-5.0_wp, -3.0_wp, 3, 10)
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1, 2 ] 
            nprint = 16
            if_save_output = .false.
            
            ! DLRA with fixed rank
            call run_lyap_DLRA_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, rkv, TOv, nprint, adjoint, home, if_save_output)
         else
            Tend = T_RK/nstep*iref
            rkv = [ 6, 10, 14 ]
            if (short_test) then
               dtv = logspace(-3.0_wp, -3.0_wp, 1, 10)
            else
               dtv = logspace(-5.0_wp, -3.0_wp, 3, 10)
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1 ] 
            nprint = 16
            if_save_output = .false.
            
            ! DLRA with fixed rank
            call run_ricc_DLRA_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, rkv, TOv, nprint, adjoint, home, if_save_output)
         end if
      else
         print *, 'Skip.'
         print *, ''
      end if
      if (if_lyapunov) then
         call reset_lyapsolver()
      !else
      !   call reset_riccsolver()
      end if

      ! Reset timers
      call global_lightROM_timer%stop('Short time: DLRA')
      call reset_timers()
      call global_lightROM_timer%add_timer('Steady-State: Runge-Kutta', start=.true.)

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    IIa.  Solution using Runge-Kutta to (close to) steady state        #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''
      
      if (run_fixed_rank_long_integration_time_test .or. &
     & run_rank_adaptive_long_integration_time_test) then
         if (if_lyapunov) then
            T_RK  = 50.0_wp
            nstep = 20
            iref  = 20

            ! Run RK integrator for the Lyapunov equation
            call run_lyap_reference_RK(LTI, Xref, Xref_RK, U0, S0, T_RK, nstep, iref, adjoint)
            call reset_lyapsolver()
         else
            T_RK  = 50.0_wp
            nstep = 20
            iref  = 20
            
            ! Run RK integrator for the Lyapunov equation
            call run_ricc_reference_RK(LTI, Xref, Xref_RK, U0, S0, T_RK, nstep, iref, adjoint)
            !call reset_riccsolver()
         end if
      else
         print *, 'Skip.'
         print *, ''
      end if

      call global_lightROM_timer%stop('Steady-State: Runge-Kutta')
      call global_lightROM_timer%add_timer('Steady-State: DLRA', start=.true.)

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    IIb.  Solution using fixed-rank DLRA                               #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      if (run_fixed_rank_long_integration_time_test) then
         if (if_lyapunov) then
            Tend = T_RK/nstep*iref
            rkv = [ 10, 20, 40 ]
            if (short_test) then
               dtv = logspace(-1.0_wp, 0.0_wp, 2, 10)
            else
               dtv = logspace(-2.0_wp, 0.0_wp, 3, 10)
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1, 2 ] 
            nprint = 40
            if_save_output = .true.
            
            ! DLRA with fixed rank
            call run_lyap_DLRA_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, rkv, TOv, nprint, adjoint, home, if_save_output)
            call reset_lyapsolver()
         else
            Tend = T_RK/nstep*iref
            rkv = [ 10, 20, 40 ]
            if (short_test) then
               dtv = logspace(-1.0_wp, 0.0_wp, 2, 10)
            else
               dtv = logspace(-2.0_wp, 0.0_wp, 3, 10)
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1 ] 
            nprint = 40
            if_save_output = .true.
            
            ! DLRA with fixed rank
            call run_ricc_DLRA_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, rkv, TOv, nprint, adjoint, home, if_save_output)
            !call reset_riccsolver()
         end if
      else
         print *, 'Skip.'
         print *, ''
      end if

      call global_lightROM_timer%stop('Steady-State: DLRA')
      call global_lightROM_timer%add_timer('Steady-State: rank-adaptive DLRA', start=.true.)

      print *, ''
      print *, '#########################################################################'
      print *, '#                                                                       #'
      print *, '#    IIc.  Solution using rank-adaptive DLRA                            #'
      print *, '#                                                                       #'
      print *, '#########################################################################'
      print *, ''

      if (run_rank_adaptive_long_integration_time_test) then
         if (if_lyapunov) then
            if (short_test) then
               dtv = logspace(-3.0_wp, 0.0_wp, 2, 10)
               tolv = [ 1e-2_wp, 1e-6_wp ]
            else
               dtv = logspace(-2.0_wp, 0.0_wp, 3, 10)
               tolv = [ 1e-2_wp, 1e-6_wp, 1e-10_wp ]
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1, 2 ]
            nprint = 60
            if_save_output = .true.
            
            ! DLRA with adaptive rank
            call run_lyap_DLRArk_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, TOv, tolv, nprint, adjoint, home, if_save_output)
            call reset_lyapsolver()
         else
            print *, 'Riccati rank-adaptive not implemented at this time'
            STOP 87
            if (short_test) then
               dtv = logspace(-3.0_wp, 0.0_wp, 2, 10)
               tolv = [ 1e-2_wp, 1e-6_wp ]
            else
               dtv = logspace(-2.0_wp, 0.0_wp, 3, 10)
               tolv = [ 1e-2_wp, 1e-6_wp, 1e-10_wp ]
            end if
            dtv = dtv(size(dtv):1:-1) ! reverse vector
            TOv  = [ 1, 2 ]
            nprint = 60
            if_save_output = .true.
            
            ! DLRA with adaptive rank
            !call run_ricc_DLRArk_test(LTI, Xref, Xref_RK, U0, S0, Tend, dtv, TOv, tolv, nprint, adjoint, home, if_save_output)
            !call reset_riccsolver()
         end if
      else
         print *, 'Skip.'
         print *, ''
      end if
   end if

   ! Compute and print timer summary
   call finalize_timers()

   return
end program demo