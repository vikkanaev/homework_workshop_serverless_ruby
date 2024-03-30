class MessagesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :set_message, only: %i[ show edit destroy ]

  # GET /messages or /messages.json
  def index
    @messages = Message.all
  end

  # GET /messages/1 or /messages/1.json
  def show
  end

  # GET /messages/new
  def new
    @message = Message.new
  end

  # GET /messages/1/edit
  def edit
  end

  # POST /messages or /messages.json
  def create
    @message = Message.new(message_params)

    if @message.save
      redirect_to message_url(@message), notice: "Message was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # DELETE /messages/1 or /messages/1.json
  def destroy
    @message.destroy!

    redirect_to messages_url, notice: "Message was successfully destroyed."
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_message
    @message = Message.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def message_params
    params.require(:message).permit(:text, :author)
  end
end
